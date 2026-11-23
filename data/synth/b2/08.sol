// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

interface IERC20 {
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

/// @notice Fee pool that keeps an append-only log of fee batches. Each batch
/// records the total share count at the time it was created; a holder's credit
/// is computed lazily by walking the log from their own cursor.
contract BatchFeeLedger {
    struct Batch {
        uint256 amount;
        uint256 totalSharesAtBatch;
    }

    IERC20 public immutable feeToken;
    IERC20 public immutable shareToken;

    Batch[] public batches;
    uint256 public totalShares;

    mapping(address => uint256) public sharesOf;
    mapping(address => uint256) public cursor;
    mapping(address => uint256) public credit;

    event BatchAdded(uint256 indexed id, uint256 amount, uint256 totalShares);
    event LiquidityAdded(address indexed user, uint256 shares);
    event LiquidityRemoved(address indexed user, uint256 shares);
    event Credited(address indexed user, uint256 amount);

    constructor(IERC20 _fee, IERC20 _share) {
        feeToken = _fee;
        shareToken = _share;
    }

    function depositFees(uint256 amount) external {
        require(totalShares > 0, "no shares");
        require(feeToken.transferFrom(msg.sender, address(this), amount), "transfer failed");
        batches.push(Batch({amount: amount, totalSharesAtBatch: totalShares}));
        emit BatchAdded(batches.length - 1, amount, totalShares);
    }

    function depositLiquidity(uint256 shares) external {
        require(shares > 0, "zero shares");
        _pokeFees(msg.sender);
        sharesOf[msg.sender] += shares;
        totalShares += shares;
        require(shareToken.transferFrom(msg.sender, address(this), shares), "transfer failed");
        emit LiquidityAdded(msg.sender, shares);
    }

    function withdrawLiquidity(uint256 shares) external {
        require(shares <= sharesOf[msg.sender], "insufficient shares");
        _pokeFees(msg.sender);
        sharesOf[msg.sender] -= shares;
        totalShares -= shares;
        require(shareToken.transfer(msg.sender, shares), "transfer failed");
        emit LiquidityRemoved(msg.sender, shares);
    }

    function claimFees() external {
        _pokeFees(msg.sender);
        uint256 amount = credit[msg.sender];
        if (amount == 0) return;
        credit[msg.sender] = 0;
        require(feeToken.transfer(msg.sender, amount), "transfer failed");
        emit Credited(msg.sender, amount);
    }

    /// @dev Walks batches from the holder's cursor to the end. Safe because every
    /// change to a holder's shares passes through here first, so sharesOf[who]
    /// equals what it was when each unprocessed batch was created.
    function _pokeFees(address who) internal {
        uint256 held = sharesOf[who];
        uint256 i = cursor[who];
        uint256 len = batches.length;
        uint256 gained;
        for (; i < len; ++i) {
            Batch storage b = batches[i];
            gained += b.amount * held / b.totalSharesAtBatch;
        }
        cursor[who] = len;
        credit[who] += gained;
    }
}
