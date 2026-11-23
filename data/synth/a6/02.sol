// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.19;

interface IERC20 {
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function transfer(address to, uint256 amount) external returns (bool);
}

// Fee distributor: revenue arrives in batches, holders have fixed weights set at deployment.
contract RevenueShareSplitter {
    uint256 public constant SCALE = 1e18;

    address public immutable treasury;
    IERC20 public immutable payoutToken;
    uint256 public immutable totalWeight;

    mapping(address => uint256) public weightOf;
    mapping(address => uint256) public cursor;
    mapping(address => uint256) public owedTo;
    address[] private _holders;

    uint256 public revenuePerWeight;
    uint256 public undistributedDust;
    uint256 public totalDeposited;

    event HolderRegistered(address indexed holder, uint256 weight);
    event RevenueDeposited(address indexed from, uint256 amount, uint256 newRevenuePerWeight);
    event HolderSynced(address indexed holder, uint256 owed);
    event Withdrawn(address indexed holder, uint256 amount);

    constructor(address treasury_, IERC20 payoutToken_, address[] memory holders, uint256[] memory weights) {
        require(treasury_ != address(0), "treasury");
        require(holders.length == weights.length && holders.length > 0, "shape");
        treasury = treasury_;
        payoutToken = payoutToken_;

        uint256 sum;
        for (uint256 i = 0; i < holders.length; i++) {
            require(holders[i] != address(0), "holder");
            require(weights[i] > 0, "weight");
            weightOf[holders[i]] = weights[i];
            _holders.push(holders[i]);
            sum = sum + weights[i];
            emit HolderRegistered(holders[i], weights[i]);
        }
        totalWeight = sum;
    }

    modifier onlyTreasury() {
        require(msg.sender == treasury, "not treasury");
        _;
    }

    function holderCount() external view returns (uint256) {
        return _holders.length;
    }

    // Pull-style deposit. Fees are split by index, not pushed to each holder.
    function depositRevenue(uint256 amount) external onlyTreasury {
        require(amount > 0, "amount");
        require(payoutToken.transferFrom(msg.sender, address(this), amount), "pull");

        uint256 scaled = amount * SCALE + undistributedDust;
        uint256 perWeight = scaled / totalWeight;
        undistributedDust = scaled - perWeight * totalWeight;
        revenuePerWeight = revenuePerWeight + perWeight;
        totalDeposited = totalDeposited + amount;

        emit RevenueDeposited(msg.sender, amount, revenuePerWeight);
    }

    // Settles the caller's accrued share into owedTo and pays it out.
    function withdraw() external returns (uint256 paid) {
        _syncHolder(msg.sender);
        paid = owedTo[msg.sender];
        require(paid > 0, "nothing owed");
        owedTo[msg.sender] = 0;
        require(payoutToken.transfer(msg.sender, paid), "transfer");
        emit Withdrawn(msg.sender, paid);
    }

    function claimableBy(address holder) external view returns (uint256) {
        uint256 w = weightOf[holder];
        if (w == 0) return owedTo[holder];
        uint256 delta = revenuePerWeight - cursor[holder];
        return owedTo[holder] + (w * delta) / SCALE;
    }

    // Anyone may bring a holder current; this does not move any funds.
    function syncHolder(address holder) external {
        _syncHolder(holder);
    }

    function _syncHolder(address holder) internal {
        uint256 w = weightOf[holder];
        uint256 index = revenuePerWeight;
        if (w > 0 && index > cursor[holder]) {
            uint256 delta = index - cursor[holder];
            owedTo[holder] = owedTo[holder] + (w * delta) / SCALE;
            emit HolderSynced(holder, owedTo[holder]);
        }
        cursor[holder] = index;
    }

    // Treasury can sweep rounding residue once it has accumulated to a meaningful amount.
    function sweepDust(address to) external onlyTreasury {
        uint256 whole = undistributedDust / SCALE;
        require(whole > 0, "no dust");
        undistributedDust = undistributedDust - whole * SCALE;
        require(payoutToken.transfer(to, whole), "sweep");
    }
}
