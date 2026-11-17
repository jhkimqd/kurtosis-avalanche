// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/// Synthetic permissioned asset. Roles model application controls, not legal compliance.
contract Ledger {
    address public immutable issuer;
    uint256 public totalSupply;
    mapping(address => bool) public participant;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    mapping(bytes32 => bool) public issued;
    mapping(address => mapping(bytes32 => bool)) public redeemed;
    event Transfer(address indexed from, address indexed to, uint256 amount);
    constructor() { issuer = msg.sender; participant[msg.sender] = true; }
    modifier onlyIssuer() { require(msg.sender == issuer, "issuer"); _; }
    function setParticipant(address actor, bool enabled) external onlyIssuer { require(actor != address(0), "zero actor"); participant[actor] = enabled; }
    function mint(bytes32 businessID, address to, uint256 amount) external onlyIssuer {
        require(!issued[businessID], "duplicate"); require(participant[to], "participant");
        issued[businessID] = true; totalSupply += amount; balanceOf[to] += amount;
        emit Transfer(address(0), to, amount);
    }
    function redeem(bytes32 businessID, uint256 amount) external {
        require(participant[msg.sender] && amount > 0, "participant or amount"); require(!redeemed[msg.sender][businessID], "duplicate");
        redeemed[msg.sender][businessID] = true; balanceOf[msg.sender] -= amount; totalSupply -= amount;
        emit Transfer(msg.sender, address(0), amount);
    }
    function approve(address spender, uint256 amount) external { require(participant[msg.sender], "participant"); allowance[msg.sender][spender] = amount; }
    function transfer(address to, uint256 amount) external { _transfer(msg.sender, to, amount); }
    function transferFrom(address from, address to, uint256 amount) external {
        if (msg.sender != from) { allowance[from][msg.sender] -= amount; }
        _transfer(from, to, amount);
    }
    function _transfer(address from, address to, uint256 amount) internal {
        require(participant[from] && participant[to] && participant[msg.sender], "participant");
        balanceOf[from] -= amount; balanceOf[to] += amount; emit Transfer(from, to, amount);
    }
}

/// Both parties authorize the exact trade; allowances alone cannot authorize a trade.
contract DeliveryVersusPayment {
    Ledger public immutable cash;
    Ledger public immutable security;
    mapping(bytes32 => bool) public settled;
    mapping(bytes32 => mapping(address => bool)) public approved;
    constructor(Ledger cash_, Ledger security_) { require(address(cash_) != address(security_), "same asset"); cash = cash_; security = security_; }
    function tradeID(bytes32 businessID, address buyer, address seller, uint256 cashAmount, uint256 units) public view returns (bytes32) {
        return keccak256(abi.encode(block.chainid, address(this), businessID, buyer, seller, cashAmount, units));
    }
    function authorize(bytes32 id, bool value) external { approved[id][msg.sender] = value; }
    function settle(bytes32 businessID, address buyer, address seller, uint256 cashAmount, uint256 units) external {
        bytes32 id = tradeID(businessID, buyer, seller, cashAmount, units);
        require(!settled[businessID], "duplicate"); require(buyer != seller && cashAmount > 0 && units > 0, "trade");
        require(approved[id][buyer] && approved[id][seller], "authorization");
        settled[businessID] = true;
        cash.transferFrom(buyer, seller, cashAmount);
        security.transferFrom(seller, buyer, units);
    }
}

contract PriceFeed {
    address public immutable admin;
    address public publisher;
    uint256 public price;
    uint256 public updatedAt;
    uint256 public round;
    constructor(address publisher_) { admin = msg.sender; publisher = publisher_; }
    function setPublisher(address next) external { require(msg.sender == admin && next != address(0), "admin"); publisher = next; }
    function publish(uint256 nextRound, uint256 nextPrice) external {
        require(msg.sender == publisher, "publisher"); require(nextRound == round + 1 && nextPrice > 0, "round");
        round = nextRound; price = nextPrice; updatedAt = block.timestamp;
    }
    function valid(uint256 maxAge, uint256 low, uint256 high) external view returns (bool) {
        return round > 0 && block.timestamp - updatedAt <= maxAge && price >= low && price <= high;
    }
}

contract OracleSettlement {
    Ledger public immutable cash;
    PriceFeed public immutable feed;
    uint256 public immutable maxAge;
    uint256 public immutable low;
    uint256 public immutable high;
    mapping(bytes32 => bool) public settled;
    constructor(Ledger cash_, PriceFeed feed_, uint256 age_, uint256 low_, uint256 high_) {
        require(age_ > 0 && low_ <= high_, "bounds"); cash = cash_; feed = feed_; maxAge = age_; low = low_; high = high_;
    }
    function settle(bytes32 id, address recipient, uint256 amount) external {
        id = keccak256(abi.encode(msg.sender, id));
        require(amount > 0, "amount"); require(!settled[id], "duplicate"); require(feed.valid(maxAge, low, high), "feed");
        settled[id] = true; cash.transferFrom(msg.sender, recipient, amount);
    }
}
