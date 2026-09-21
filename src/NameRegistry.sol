// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

interface IRegistryToken {
    function balanceOf(address who) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

/// @notice Annual name leases and equal annual fee shares per snapshot holder address.
/// @dev See README for snapshot liveness, current-holder proofs, and Sybil assumptions.
contract NameRegistry {
    uint256 public constant YEAR = 365 days;
    uint256 public constant FEE = 100 ether;
    uint256 public constant MAX_BATCH = 200;
    IRegistryToken public immutable token;

    struct Name {
        address holder;
        uint256 expiresAt;
    }

    mapping(bytes32 => Name) public names;
    bytes32[] public nameIds;
    mapping(bytes32 => bool) private known;
    mapping(address => uint256) public eligibleRound;
    mapping(address => uint256) public claimedRound;
    uint256 public poolBalance;
    uint256 public round;
    uint256 public nextRoundAt;
    uint256 public snapshotAt;
    uint256 public snapshotCursor;
    uint256 public snapshotPool;
    uint256 public holderCount;
    uint256 public share;
    bool public snapshotting;
    bool private entered;

    error InvalidToken();
    error InvalidName();
    error Unavailable();
    error NotHolder();
    error InvalidRecipient();
    error SnapshotInProgress();
    error NoSnapshot();
    error TooEarly();
    error InvalidBatch();
    error NotEligible();
    error AlreadyClaimed();
    error TokenPaymentFailed();
    error Reentrancy();

    event Registered(bytes32 indexed id, string name, address indexed holder, uint256 expiresAt);
    event Renewed(bytes32 indexed id, uint256 expiresAt);
    event NameTransferred(bytes32 indexed id, address indexed from, address indexed to);
    event RoundStarted(uint256 indexed round, uint256 snapshotAt, uint256 pool);
    event SnapshotProgress(uint256 indexed round, uint256 cursor, uint256 holders);
    event RoundReady(uint256 indexed round, uint256 holders, uint256 share);
    event Claimed(uint256 indexed round, address indexed holder, uint256 amount);

    constructor(address token_) {
        if (token_ == address(0) || token_.code.length == 0) revert InvalidToken();
        token = IRegistryToken(token_);
        nextRoundAt = block.timestamp + YEAR;
    }

    modifier nonReentrant() {
        if (entered) revert Reentrancy();
        entered = true;
        _;
        entered = false;
    }

    modifier mutableNames() {
        if (snapshotting) revert SnapshotInProgress();
        _;
    }

    function nameId(string memory name_) public pure returns (bytes32) {
        bytes memory value = bytes(name_);
        if (value.length < 3 || value.length > 32) revert InvalidName();
        for (uint256 i; i < value.length; ++i) {
            if (value[i] < 0x61 || value[i] > 0x7a) revert InvalidName();
        }
        return keccak256(value);
    }

    function nameCount() external view returns (uint256) {
        return nameIds.length;
    }

    /// @notice Acquire an absent or expired name for exactly one year.
    function register(string calldata name_) external nonReentrant mutableNames {
        bytes32 id = nameId(name_);
        if (names[id].expiresAt > block.timestamp) revert Unavailable();
        names[id] = Name(msg.sender, block.timestamp + YEAR);
        if (!known[id]) {
            known[id] = true;
            nameIds.push(id);
        }
        poolBalance += FEE;
        emit Registered(id, name_, msg.sender, block.timestamp + YEAR);
        _collect();
    }

    /// @notice Add one prepaid year to a live lease, paying the same fixed fee.
    function renew(string calldata name_) external nonReentrant mutableNames {
        bytes32 id = nameId(name_);
        _requireHolder(id);
        names[id].expiresAt += YEAR;
        poolBalance += FEE;
        emit Renewed(id, names[id].expiresAt);
        _collect();
    }

    function transferName(string calldata name_, address to) external nonReentrant mutableNames {
        bytes32 id = nameId(name_);
        _requireHolder(id);
        if (to == address(0) || to == msg.sender) revert InvalidRecipient();
        names[id].holder = to;
        emit NameTransferred(id, msg.sender, to);
    }

    /// @notice Permissionless annual snapshot. Prior unclaimed funds roll into this round.
    function startRound() external nonReentrant mutableNames {
        if (block.timestamp < nextRoundAt) revert TooEarly();
        ++round;
        snapshotAt = block.timestamp;
        nextRoundAt = block.timestamp + YEAR;
        snapshotCursor = 0;
        snapshotPool = poolBalance;
        holderCount = 0;
        share = 0;
        snapshotting = true;
        emit RoundStarted(round, snapshotAt, snapshotPool);
    }

    /// @notice Anyone may advance the frozen snapshot; each call processes at most 200 names.
    function processSnapshot(uint256 count) external nonReentrant {
        if (!snapshotting) revert NoSnapshot();
        if (count == 0 || count > MAX_BATCH) revert InvalidBatch();
        uint256 end = snapshotCursor + count;
        if (end > nameIds.length) end = nameIds.length;
        for (uint256 i = snapshotCursor; i < end; ++i) {
            Name storage lease = names[nameIds[i]];
            if (lease.expiresAt > snapshotAt && eligibleRound[lease.holder] != round) {
                eligibleRound[lease.holder] = round;
                ++holderCount;
            }
        }
        snapshotCursor = end;
        emit SnapshotProgress(round, end, holderCount);
        if (end == nameIds.length) {
            snapshotting = false;
            share = holderCount == 0 ? 0 : snapshotPool / holderCount;
            emit RoundReady(round, holderCount, share);
        }
    }

    /// @notice Claim using any currently held live name as proof. Rights stay with snapshot addresses.
    function claim(string calldata heldName) external nonReentrant mutableNames {
        _requireHolder(nameId(heldName));
        if (round == 0 || eligibleRound[msg.sender] != round || share == 0) revert NotEligible();
        if (claimedRound[msg.sender] == round) revert AlreadyClaimed();
        claimedRound[msg.sender] = round;
        poolBalance -= share;
        emit Claimed(round, msg.sender, share);
        uint256 beforeBalance = token.balanceOf(address(this));
        uint256 beforeRecipient = token.balanceOf(msg.sender);
        if (!token.transfer(msg.sender, share)) revert TokenPaymentFailed();
        if (
            token.balanceOf(address(this)) + share != beforeBalance
                || token.balanceOf(msg.sender) != beforeRecipient + share
        ) revert TokenPaymentFailed();
    }

    function _requireHolder(bytes32 id) private view {
        Name storage lease = names[id];
        if (lease.holder != msg.sender || lease.expiresAt <= block.timestamp) revert NotHolder();
    }

    function _collect() private {
        uint256 beforeBalance = token.balanceOf(address(this));
        if (!token.transferFrom(msg.sender, address(this), FEE)) revert TokenPaymentFailed();
        if (token.balanceOf(address(this)) != beforeBalance + FEE) revert TokenPaymentFailed();
    }
}
