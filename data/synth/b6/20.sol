// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IERC20 {
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

/// @notice Restaking across strategies. Operators carry a magnitude that is reduced by slashing; stakers sync lazily.
contract RestakeWithWithdrawalDelay {
    uint256 private constant PRECISION = 1e18;
    uint256 public constant WITHDRAW_DELAY = 7 days;

    struct Strategy {
        IERC20 token;
        uint256 totalShares;
        uint256 totalTokens;
    }

    struct Queued {
        address staker;
        uint256 strategyId;
        uint256 shares;
        uint256 tokens;
        uint256 startedAt;
    }

    address public immutable owner;
    Strategy[] public strategies;

    mapping(address => uint256) public magnitude;
    mapping(address => address) public delegatedTo;
    mapping(address => uint256) public slashSnap;
    mapping(address => mapping(uint256 => uint256)) public stakerShares;
    mapping(address => uint256) public nonces;
    mapping(bytes32 => Queued) public queued;

    event OperatorRegistered(address indexed operator);
    event OperatorSlashed(address indexed operator, uint256 bps, uint256 magnitude);
    event Delegated(address indexed staker, address indexed operator);
    event Restaked(address indexed staker, uint256 indexed strategyId, uint256 tokens, uint256 shares);
    event WithdrawalQueued(bytes32 indexed root, address indexed staker, uint256 strategyId, uint256 tokens);
    event WithdrawalCompleted(bytes32 indexed root, uint256 tokens);

    constructor() {
        owner = msg.sender;
    }

    modifier onlyOwner() {
        require(msg.sender == owner, "not owner");
        _;
    }

    function addStrategy(IERC20 token) external onlyOwner returns (uint256 id) {
        strategies.push(Strategy({token: token, totalShares: 0, totalTokens: 0}));
        id = strategies.length - 1;
    }

    function registerOperator(address op) external onlyOwner {
        magnitude[op] = PRECISION;
        emit OperatorRegistered(op);
    }

    function slashOperator(address op, uint256 bps) external onlyOwner {
        require(bps <= 10_000, "bps");
        require(magnitude[op] > 0, "unregistered");
        magnitude[op] = (magnitude[op] * (10_000 - bps)) / 10_000;
        emit OperatorSlashed(op, bps, magnitude[op]);
    }

    function _operatorMagnitude(address op) internal view returns (uint256) {
        if (op == address(0)) return PRECISION;
        return magnitude[op];
    }

    function _syncStakerView(address staker) internal {
        uint256 idx = _operatorMagnitude(delegatedTo[staker]);
        uint256 snap = slashSnap[staker];
        if (snap == 0) {
            slashSnap[staker] = idx;
            return;
        }
        if (snap == idx) return;
        uint256 n = strategies.length;
        for (uint256 i = 0; i < n; i++) {
            stakerShares[staker][i] = (stakerShares[staker][i] * idx) / snap;
        }
        slashSnap[staker] = idx;
    }

    function delegate(address op) external {
        require(delegatedTo[msg.sender] == address(0), "already delegated");
        require(slashSnap[msg.sender] == 0, "has restake history");
        require(magnitude[op] > 0, "unregistered");
        delegatedTo[msg.sender] = op;
        emit Delegated(msg.sender, op);
    }

    function depositToStrategy(uint256 strategyId, uint256 amount) external {
        require(strategyId < strategies.length, "strategy");
        require(amount > 0, "zero");
        _syncStakerView(msg.sender);
        Strategy storage s = strategies[strategyId];
        uint256 minted = s.totalTokens == 0 ? amount : (amount * s.totalShares) / s.totalTokens;
        require(minted > 0, "dust");
        stakerShares[msg.sender][strategyId] += minted;
        s.totalShares += minted;
        s.totalTokens += amount;
        emit Restaked(msg.sender, strategyId, amount, minted);
        require(s.token.transferFrom(msg.sender, address(this), amount), "pull");
    }

    function queueWithdrawal(uint256 strategyId, uint256 shares) external returns (bytes32 root) {
        require(shares > 0, "zero");
        _syncStakerView(msg.sender);
        require(stakerShares[msg.sender][strategyId] >= shares, "insufficient");
        Strategy storage s = strategies[strategyId];
        uint256 tokens = (shares * s.totalTokens) / s.totalShares;
        stakerShares[msg.sender][strategyId] -= shares;
        s.totalShares -= shares;
        s.totalTokens -= tokens;
        nonces[msg.sender] += 1;
        root = keccak256(abi.encode(msg.sender, strategyId, nonces[msg.sender], block.timestamp));
        queued[root] = Queued({staker: msg.sender, strategyId: strategyId, shares: shares, tokens: tokens, startedAt: block.timestamp});
        emit WithdrawalQueued(root, msg.sender, strategyId, tokens);
    }

    function completeWithdrawal(bytes32 root) external returns (uint256 tokens) {
        Queued storage q = queued[root];
        require(q.staker == msg.sender, "not staker");
        require(block.timestamp >= q.startedAt + WITHDRAW_DELAY, "delay");
        tokens = q.tokens;
        IERC20 tok = strategies[q.strategyId].token;
        delete queued[root];
        emit WithdrawalCompleted(root, tokens);
        require(tok.transfer(msg.sender, tokens), "xfer");
    }
}
