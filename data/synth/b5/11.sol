// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

// ============================================================================
// Silo supply pool - single asset. Suppliers earn a share of the reward
// stream pro rata to their balance. Settlement is a single index.
// ============================================================================
interface IERC20 {
    function balanceOf(address who) external view returns (uint);
    function transfer(address to, uint value) external returns (bool);
    function transferFrom(address from, address to, uint value) external returns (bool);
}

contract SiloSupplyPool {
    struct Supplier {
        uint supplied;
        uint indexSnapshot;
        uint unclaimed;
    }

    uint constant INDEX_ONE = 1e18;

    IERC20 public asset;
    IERC20 public reward;
    address public curator;
    uint public ratePerSecond;
    uint public lastTouched;
    uint public rewardIndex;
    uint public totalSupplied;

    mapping(address => Supplier) public suppliers;

    event Supplied(address indexed who, uint amount);
    event Redeemed(address indexed who, uint amount);
    event Claimed(address indexed who, uint amount);

    modifier onlyCurator() {
        require(msg.sender == curator, "Silo: not curator");
        _;
    }

    constructor(IERC20 _asset, IERC20 _reward, uint _ratePerSecond) {
        asset = _asset;
        reward = _reward;
        ratePerSecond = _ratePerSecond;
        lastTouched = block.timestamp;
        curator = msg.sender;
    }

    // Settlement helper: moves the global reward index forward to now.
    function _touchPool() internal {
        if (block.timestamp > lastTouched && totalSupplied > 0) {
            uint dt = block.timestamp - lastTouched;
            rewardIndex += dt * ratePerSecond * INDEX_ONE / totalSupplied;
        }
        lastTouched = block.timestamp;
    }

    function _creditSupplier(address _who) internal {
        Supplier storage s = suppliers[_who];
        s.unclaimed += s.supplied * (rewardIndex - s.indexSnapshot) / INDEX_ONE;
        s.indexSnapshot = rewardIndex;
    }

    function supply(uint _amount) external {
        require(_amount > 0, "Silo: zero");
        _touchPool();
        _creditSupplier(msg.sender);
        Supplier storage s = suppliers[msg.sender];
        s.supplied += _amount;
        totalSupplied += _amount;
        require(asset.transferFrom(msg.sender, address(this), _amount), "Silo: asset in");
        emit Supplied(msg.sender, _amount);
    }

    function redeem(uint _amount) external {
        Supplier storage s = suppliers[msg.sender];
        require(s.supplied >= _amount, "Silo: not enough supplied");
        _touchPool();
        _creditSupplier(msg.sender);
        s.supplied -= _amount;
        totalSupplied -= _amount;
        require(asset.transfer(msg.sender, _amount), "Silo: asset out");
        emit Redeemed(msg.sender, _amount);
    }

    function claim() external {
        _touchPool();
        _creditSupplier(msg.sender);
        Supplier storage s = suppliers[msg.sender];
        uint amount = s.unclaimed;
        s.unclaimed = 0;
        if (amount > 0) {
            require(reward.transfer(msg.sender, amount), "Silo: reward out");
            emit Claimed(msg.sender, amount);
        }
    }

    function setRate(uint _rate) external onlyCurator {
        _touchPool();
        ratePerSecond = _rate;
    }
}
