// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import {IERC20, SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IWETH} from "./libs/IWETH.sol";

contract LimitOrder is Ownable(msg.sender), ReentrancyGuard {
    using SafeERC20 for IERC20;

    enum Status {
        PENDING,
        CANCELED,
        EXECUTED
    }

    struct OrderInfo {
        uint256 id;
        address receiver;
        address tokenIn;
        address tokenOut;
        uint256 amount;
        uint256 price;
        uint256 creationTime;
        uint256 expireTime;
        bool isSell;
        bool executed;
        Status status;
        uint256 fee;
    }

    OrderInfo[] public orderInfo;
    address public constant router = 0x6BF228eb7F8ad948d37deD07E595EfddfaAF88A6;
    address public operator;
    mapping(address => bool) public whitelist;
    bool public enableWhiteList = false;
    address public weth;
    uint256 public operatorFee = 5000 ether;

    event OrderCreated(
        uint256 id,
        address receiver,
        address tokenIn,
        address tokenOut,
        uint256 amount,
        uint256 price,
        uint256 creationTime,
        uint256 expireTime,
        bool isSell,
        bool executed
    );
    event OrderEdited(
        uint256 id,
        uint256 amount,
        uint256 price,
        uint256 expiration,
        bool isSell
    );
    event OrderCanceled(uint256 id, uint256 time);
    event OrderExecuted(uint256 id, uint256 out, uint256 time);
    event OperatorChanged(address operator);
    event OperatorFeeChanged(uint256 fee);

    modifier onlyOperator() {
        require(msg.sender == operator, "Not Operator");
        _;
    }

    constructor(address _weth, address _operator) {
        weth = _weth;
        operator = _operator;
    }

    function createOrder(
        address _receiver,
        address _tokenIn,
        address _tokenOut,
        uint256 _amount,
        uint256 _price,
        uint256 _expiration,
        bool _isSell
    ) public payable nonReentrant {
        require(_amount > 0, "zero amount");
        require(_expiration > 0, "invalid expire");
        require(
            !enableWhiteList ||
                whitelist[msg.sender] ||
                msg.sender == owner() ||
                msg.sender == operator,
            "not whitelist"
        );
        uint256 fee = 0;
        if (_tokenIn == address(0)) {
            require(
                msg.value >= _amount + operatorFee,
                "should pay operator fee and amount"
            );
            fee = msg.value - _amount;
            // IWETH(weth).deposit{value: _amount}();
            // if (msg.value > _amount + operatorFee)
            //     payable(operator).transfer(msg.value - _amount - operatorFee);
        } else {
            require(msg.value >= operatorFee, "should pay operator fee");
            IERC20(_tokenIn).safeTransferFrom(
                msg.sender,
                address(this),
                _amount
            );
            fee = msg.value;
            // if (msg.value > operatorFee)
            //     payable(operator).transfer(msg.value - operatorFee);
        }
        // payable(operator).transfer(operatorFee);

        orderInfo.push(
            OrderInfo({
                id: orderInfo.length,
                receiver: _receiver,
                tokenIn: _tokenIn,
                tokenOut: _tokenOut,
                amount: _amount,
                price: _price,
                creationTime: block.timestamp,
                expireTime: block.timestamp + _expiration,
                isSell: _isSell,
                executed: false,
                status: Status.PENDING,
                fee: fee
            })
        );
        emit OrderCreated(
            orderInfo.length - 1,
            _receiver,
            _tokenIn,
            _tokenOut,
            _amount,
            _price,
            block.timestamp,
            block.timestamp + _expiration,
            _isSell,
            false
        );
    }

    function editOrder(
        uint256 _id,
        uint256 _amount,
        uint256 _price,
        uint256 _expiration,
        bool _isSell
    ) public payable nonReentrant {
        OrderInfo storage order = orderInfo[_id];
        require(order.receiver == msg.sender, "Not order owner");
        require(order.status != Status.CANCELED, "Already Canceled");
        if (order.amount > _amount) {
            uint256 amount = order.amount - _amount;
            if (order.tokenIn == address(0)) {
                // IWETH(weth).withdraw(amount);
                payable(msg.sender).transfer(amount);
            } else {
                IERC20(order.tokenIn).safeTransfer(msg.sender, amount);
            }
        } else {
            uint256 amount = _amount - order.amount;
            if (order.tokenIn == address(0)) {
                require(msg.value >= amount, "incorrect amount");
                // IWETH(weth).deposit{value: amount}();
            } else {
                IERC20(order.tokenIn).safeTransferFrom(
                    msg.sender,
                    address(this),
                    amount
                );
            }
        }
        order.amount = _amount;
        order.price = _price;
        order.expireTime = order.creationTime + _expiration;
        order.isSell = _isSell;
        if (order.amount == 0) {
            order.status = Status.CANCELED;
            payable(msg.sender).transfer(order.fee);
        }

        emit OrderEdited(
            _id,
            order.amount,
            order.price,
            order.expireTime,
            order.isSell
        );
    }

    function cancelOrder(uint256 _id) public payable nonReentrant {
        OrderInfo storage order = orderInfo[_id];
        require(order.receiver == msg.sender, "Not order owner");
        require(order.status != Status.CANCELED, "Already Canceled");
        uint256 amount = order.amount;
        if (order.tokenIn == address(0)) {
            // IWETH(weth).withdraw(amount);
            payable(msg.sender).transfer(amount);
        } else {
            IERC20(order.tokenIn).safeTransfer(msg.sender, amount);
        }
        payable(msg.sender).transfer(order.fee);
        order.status = Status.CANCELED;
        emit OrderCanceled(_id, block.timestamp);
    }

    function executeOrder(
        uint256 _id,
        bytes calldata _calldata,
        uint256 _value
    ) public onlyOperator {
        uint256 gas = gasleft();
        OrderInfo storage order = orderInfo[_id];
        uint256 beforeBalance = IERC20(order.tokenOut).balanceOf(address(this));
        if (order.tokenIn != address(0)) {
            IERC20(order.tokenIn).approve(router, order.amount);
        }
        (bool success, ) = router.call{value: _value}(_calldata);
        if (success) {
            order.executed = true;
            uint256 afterBalance = IERC20(order.tokenOut).balanceOf(
                address(this)
            );
            IERC20(order.tokenOut).safeTransfer(
                order.receiver,
                afterBalance - beforeBalance
            );
            order.status = Status.EXECUTED;
            emit OrderExecuted(
                order.id,
                afterBalance - beforeBalance,
                block.timestamp
            );
            uint256 gasFee = tx.gasprice * (gas - gasleft() + 50000);
            payable(operator).transfer(gasFee);
            if (order.fee > gasFee)
                payable(order.receiver).transfer(order.fee - gasFee);
        }
    }

    function executeMultipleOrder(
        uint256[] memory _ids,
        bytes[] calldata _calldatas,
        uint256[] memory _values
    ) public onlyOperator {
        for (uint256 i = 0; i < _ids.length; i++) {
            uint256 gas = gasleft();
            uint256 _id = _ids[i];
            bytes calldata _calldata = _calldatas[i];
            uint256 _value = _values[i];
            OrderInfo storage order = orderInfo[_id];
            uint256 beforeBalance = IERC20(order.tokenOut).balanceOf(
                address(this)
            );
            if (order.tokenIn != address(0)) {
                IERC20(order.tokenIn).approve(router, order.amount);
            }
            (bool success, ) = router.call{value: _value}(_calldata);
            if (success) {
                order.executed = true;
                uint256 afterBalance = IERC20(order.tokenOut).balanceOf(
                    address(this)
                );
                IERC20(order.tokenOut).safeTransfer(
                    order.receiver,
                    afterBalance - beforeBalance
                );
                order.status = Status.EXECUTED;
                emit OrderExecuted(
                    order.id,
                    afterBalance - beforeBalance,
                    block.timestamp
                );
                uint256 gasFee = tx.gasprice * (gas - gasleft() + 50000);
                payable(operator).transfer(gasFee);
                if (order.fee > gasFee)
                    payable(order.receiver).transfer(order.fee - gasFee);
            }
        }
    }

    function setOperator(address _new) public onlyOwner {
        operator = _new;
        emit OperatorChanged(operator);
    }

    function setOperatorFee(uint256 _new) public onlyOwner {
        operatorFee = _new;
        emit OperatorFeeChanged(operatorFee);
    }

    function setWhitelist(address[] memory _addresses, bool _en)
        public
        onlyOwner
    {
        for (uint256 i = 0; i < _addresses.length; i++) {
            whitelist[_addresses[i]] = _en;
        }
    }

    function toggleEnableWhitelist() public onlyOwner {
        enableWhiteList = !enableWhiteList;
    }

    function getOrderLength() public view returns (uint256) {
        return orderInfo.length;
    }

    function getOrders(uint256 size, uint256 cursor)
        public
        view
        returns (OrderInfo[] memory)
    {
        uint256 length = size;
        if (length > orderInfo.length - cursor) {
            length = orderInfo.length - cursor;
        }
        OrderInfo[] memory orderInfos = new OrderInfo[](length);
        for (uint256 i = 0; i < length; i++) {
            orderInfos[i] = orderInfo[i + cursor];
        }
        return orderInfos;
    }

    receive() external payable {}
}
