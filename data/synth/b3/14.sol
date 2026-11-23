// SPDX-License-Identifier: MIT
pragma solidity 0.8.21;

interface IERC20 {
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

/// @notice Block-denominated deposit vault. Each position is a packed record: amount, rewards, last block.
contract BlockDepositVault {
    error ZeroAmount();
    error AmountTooLarge(uint256 amount);

    uint256 private constant PRECISION = 1e18;

    IERC20 public immutable token;
    uint256 public immutable ratePerBlock;

    /// @dev Three fields in one 256-bit slot.
    struct Position {
        uint96 amount;
        uint96 rewards;
        uint64 lastBlock;
    }
    mapping(address => Position) public positions;

    event Deposited(address indexed user, uint256 amount);
    event Withdrawn(address indexed user, uint256 amount);
    event Harvested(address indexed user, uint256 amount);

    constructor(IERC20 _token, uint256 _ratePerBlock) {
        token = _token;
        ratePerBlock = _ratePerBlock;
    }

    /// @dev Accrues block rewards on the current amount, then stamps the block.
    function _checkpointBlock(address who) internal {
        Position storage p = positions[who];
        if (p.lastBlock != 0 && p.amount > 0) {
            uint256 blocksElapsed = block.number - p.lastBlock;
            uint256 gain = (uint256(p.amount) * blocksElapsed * ratePerBlock) / PRECISION;
            p.rewards += uint96(gain);
        }
        p.lastBlock = uint64(block.number);
    }

    function deposit(uint256 amount) external {
        if (amount == 0) revert ZeroAmount();
        _checkpointBlock(msg.sender);
        Position storage p = positions[msg.sender];
        uint256 next = uint256(p.amount) + amount;
        if (next > type(uint96).max) revert AmountTooLarge(next);
        p.amount = uint96(next);
        require(token.transferFrom(msg.sender, address(this), amount), "pull failed");
        emit Deposited(msg.sender, amount);
    }

    function withdraw(uint256 amount) external {
        _checkpointBlock(msg.sender);
        Position storage p = positions[msg.sender];
        require(p.amount >= amount, "insufficient");
        p.amount -= uint96(amount);
        require(token.transfer(msg.sender, amount), "push failed");
        emit Withdrawn(msg.sender, amount);
    }

    function harvest() external {
        _checkpointBlock(msg.sender);
        Position storage p = positions[msg.sender];
        uint256 amount = p.rewards;
        require(amount > 0, "nothing to harvest");
        p.rewards = 0;
        require(token.transfer(msg.sender, amount), "push failed");
        emit Harvested(msg.sender, amount);
    }
}
