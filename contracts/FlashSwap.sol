//SPDX-License-Identifier: Unlicense
pragma solidity >=0.6.6;

import "hardhat/console.sol";

// Uniswap interface and library imports
import "./libraries/UniswapV2Library.sol";
import "./libraries/SafeERC20.sol";
import "./interfaces/IUniswapV2Router01.sol";
import "./interfaces/IUniswapV2Router02.sol";
import "./interfaces/IUniswapV2Pair.sol";
import "./interfaces/IUniswapV2Factory.sol";
import "./interfaces/IERC20.sol";

contract UniswapCrossFlash {
    using SafeERC20 for IERC20;

    // Factory and Routing Addresses
    address private constant UNISWAP_FACTORY =
        0x5C69bEe701ef814a2B6a3EDD4B1652CB9cc5aA6f;
    address private constant UNISWAP_ROUTER =
        0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D;
    address private constant SUSHI_FACTORY =
        0xC0AEe478e3658e2610c5F7A4A2E1777cE9e4f2Ac;
    address private constant SUSHI_ROUTER =
        0xd9e1cE17f2641f24aE83637ab66a2cca9C378B9F;

    // Token Addresses - impove -> add ability to put addreses as variables when calling smart contract rather than fixing them
    // If we want to test this on testnet we need to change token addresses to testnets addresses
    address private constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address private constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address private constant LINK = 0x514910771AF9Ca656af840dff83E8264EcF986CA;

    // Trade Variables
    uint256 private deadline = block.timestamp + 1 days;
    uint256 private constant MAX_INT =
        115792089237316195423570985008687907853269984665640564039457584007913129639935; // or 2**256-1 max integer in SOLIDITY

    // FUND SMART CONTRACT
    // Provides a function to allow contract to be funded
    function fundFlashSwapContract(
        address _owner,
        address _token,
        uint256 _amount
    ) public {
        IERC20(_token).transferFrom(_owner, address(this), _amount); // This allow us to transfer tokens into this smart contract
    }

    // GET CONTRACT BALANCE
    // Allows public view of balance for contract
    function getBalanceOfToken(address _address) public view returns (uint256) {
        return IERC20(_address).balanceOf(address(this));
    }

    // PLACE A TRADE FUNCTION
    // Executed placing a trade
    function placeTrade(
        address _fromToken,
        address _toToken,
        uint256 _amountIn,
        address factory,
        address router
    ) private returns (uint256) {
        address pair = IUniswapV2Factory(factory).getPair(_fromToken, _toToken);
        require(pair != address(0), "Pool does not exist");

        // Calculate Amount Out
        address[] memory path = new address[](2);
        path[0] = _fromToken;
        path[1] = _toToken;
        uint256 amountRequired = IUniswapV2Router01(router).getAmountsOut(
            _amountIn,
            path
        )[1];
        console.log("amountRequired", amountRequired);

        // Perform Arbitrage - Swap for another token
        uint256 amountReceived = IUniswapV2Router01(router)
            .swapExactTokensForTokens(
                _amountIn,
                amountRequired,
                path,
                address(this),
                deadline
            )[1]; // We will get second item in array

        console.log("amountReceived", amountReceived);

        require(amountReceived > 0, "Aborted Tx: Trade retured zero");
        return amountReceived;
    }

    // CHCECK PROFITABILITY
    // Checks wheter output > input
    function checkProfitability(uint256 _input, uint256 _output)
        private
        returns (bool)
    {
        return _output > _input; // If output not greater than input it returns false
    }

    // INITIATE ARBITRAGE
    // Begins receiving loan and performing arbitrage trades
    function startArbitrage(address _tokenBorrow, uint256 _amount) external {
        IERC20(WETH).safeApprove(address(UNISWAP_ROUTER), MAX_INT);
        IERC20(USDC).safeApprove(address(UNISWAP_ROUTER), MAX_INT);
        IERC20(LINK).safeApprove(address(UNISWAP_ROUTER), MAX_INT);

        IERC20(WETH).safeApprove(address(SUSHI_ROUTER), MAX_INT);
        IERC20(USDC).safeApprove(address(SUSHI_ROUTER), MAX_INT);
        IERC20(LINK).safeApprove(address(SUSHI_ROUTER), MAX_INT);

        // Get the Factory Pair address for combined tokens
        address pair = IUniswapV2Factory(UNISWAP_FACTORY).getPair(
            _tokenBorrow,
            WETH
        );

        // Return error if combination does not exist
        require(pair != address(0), "Pool does not exist");

        // Figure out which token (0 or 1) has the amount and assign
        address token0 = IUniswapV2Pair(pair).token0();
        address token1 = IUniswapV2Pair(pair).token1();
        uint256 amount0Out = _tokenBorrow == token0 ? _amount : 0; // if token borrow = token0 then that is the amount/amount gets assign to that token otherwise assign 0
        uint256 amount1Out = _tokenBorrow == token1 ? _amount : 0;

        // Passing data as bytes so that the 'swap' function knows it's flashloan/flashswap
        bytes memory data = abi.encode(_tokenBorrow, _amount, msg.sender); // We are encoding this with abi because it will be passed through to pancakeCall()

        // Execute the initial swap to get the loan
        IUniswapV2Pair(pair).swap(amount0Out, amount1Out, address(this), data); //Without data parameter it would not be a flashloan because we are passing this contract know its flashswap
    }

    function uniswapV2Call(
        address _sender,
        uint256 _amount0,
        uint256 _amount1,
        bytes calldata data
    ) external {
        // Ensure this request came from the contract
        address token0 = IUniswapV2Pair(msg.sender).token0();
        address token1 = IUniswapV2Pair(msg.sender).token1();
        address pair = IUniswapV2Factory(UNISWAP_FACTORY).getPair(
            token0,
            token1
        );
        require(msg.sender == pair, "The sender needs to match pair contract");
        require(
            _sender == address(this),
            "The sender should match this contract"
        );

        // Decode data for calculating the repayment
        (address tokenBorrow, uint256 amount, address myAddress) = abi.decode(
            data,
            (address, uint256, address)
        ); // We are decoding the data passed fromm startArbitrage()

        // Calculate the amount to repay at the end
        uint256 fee = ((amount * 3) / 997) + 1; // Can be found in documentation for FlashSwaps in UniswapV2
        uint256 amountToRepay = amount + fee;

        // DO ARBITRAGE

        // Assign loan amount
        uint256 loanAmount = _amount0 > 0 ? _amount0 : _amount1;

        // Trade 1
        uint256 trade1Acquired = placeTrade(
            USDC, // we got our loan in USDC
            LINK, // we gonna swap it for LINK
            loanAmount,
            UNISWAP_FACTORY, // We do this transaction within UNISWAP
            UNISWAP_ROUTER
        );

        // Trade 2
        uint256 trade2Acquired = placeTrade(
            LINK,
            USDC,
            trade1Acquired,
            SUSHI_FACTORY, // We swap our Link on SUSHISWAP back to USDC
            SUSHI_ROUTER
        );

        //// CHECK PROFITABILITY
        //bool profCheck = checkProfitability(amountToRepay, trade2Acquired);
        //require(profCheck, "Arbitrage not profitable");

        //// Pay Myself
        //IERC20 otherToken = IERC20(USDC);
        //otherToken.transfer(myAddress, trade2Acquired - amountToRepay);

        //console.log(myAddress);

        // Pay loan back
        IERC20(tokenBorrow).transfer(pair, amountToRepay); // Here we pay our loan back
    }
}
