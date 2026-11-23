// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

interface IERC20 {
    function transfer(address to, uint256 amount) external returns (bool);
}

/// @notice Daily quests. Active quests score points at each epoch boundary, then expire.
contract QuestBoard {
    error EpochOverflow();
    error NotActive(uint256 have, uint256 want);

    uint256 public constant EPOCH = 1 days;
    uint256 public constant POINTS_PER_QUEST = 100;
    uint256 public constant TOKENS_PER_POINT = 1e15;

    IERC20 public immutable rewardToken;

    struct Questor {
        uint256 active;
        uint256 points;
        uint256 lastEpoch;
    }
    mapping(address => Questor) public questors;

    event QuestJoined(address indexed user, uint256 count);
    event QuestAbandoned(address indexed user, uint256 count);
    event PointsClaimed(address indexed user, uint256 points, uint256 tokens);

    constructor(IERC20 _reward) {
        rewardToken = _reward;
    }

    function currentEpoch() public view returns (uint256) {
        return block.timestamp / EPOCH;
    }

    /// @dev Credits points for quests that ran through an epoch boundary, then retires them.
    function _rollEpoch(address who) internal {
        uint256 nowEpoch = currentEpoch();
        Questor storage q = questors[who];
        if (nowEpoch > q.lastEpoch) {
            q.points += q.active * POINTS_PER_QUEST;
            q.active = 0;
            q.lastEpoch = nowEpoch;
        }
    }

    function joinQuests(uint256 count) external {
        _rollEpoch(msg.sender);
        Questor storage q = questors[msg.sender];
        if (q.lastEpoch == 0) q.lastEpoch = currentEpoch();
        q.active += count;
        emit QuestJoined(msg.sender, count);
    }

    function abandonQuests(uint256 count) external {
        _rollEpoch(msg.sender);
        Questor storage q = questors[msg.sender];
        if (q.active < count) revert NotActive(q.active, count);
        q.active -= count;
        emit QuestAbandoned(msg.sender, count);
    }

    function claimPoints() external {
        _rollEpoch(msg.sender);
        Questor storage q = questors[msg.sender];
        uint256 pts = q.points;
        require(pts > 0, "no points");
        q.points = 0;
        uint256 tokens = pts * TOKENS_PER_POINT;
        require(rewardToken.transfer(msg.sender, tokens), "push failed");
        emit PointsClaimed(msg.sender, pts, tokens);
    }
}
