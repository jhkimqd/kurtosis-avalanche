// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;
/// Fixed-supply devnet asset; no real-world redemption promise.
contract CashToken {
    string public constant name = 'Local Cash';
    string public constant symbol = 'CASH';
    uint8 public constant decimals = 18;
    address public immutable admin = msg.sender;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    event Transfer(address indexed from,address indexed to,uint256 amount);
    event Approval(address indexed owner,address indexed spender,uint256 amount);
    constructor() { totalSupply=10**27; balanceOf[msg.sender]=totalSupply; emit Transfer(address(0),msg.sender,totalSupply); }
    function approve(address spender,uint256 amount) external returns(bool){allowance[msg.sender][spender]=amount;emit Approval(msg.sender,spender,amount);return true;}
    function transfer(address to,uint256 amount) external returns(bool){_transfer(msg.sender,to,amount);return true;}
    function transferFrom(address from,address to,uint256 amount) external returns(bool){allowance[from][msg.sender]-=amount;_transfer(from,to,amount);return true;}
    function _transfer(address from,address to,uint256 amount) internal {require(to!=address(0),'recipient');balanceOf[from]-=amount;balanceOf[to]+=amount;emit Transfer(from,to,amount);}
}
