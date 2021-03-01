pragma solidity 0.7.4;

interface IUniswapV2Factory {
    function getPair(address, address) external view returns (address);
}
