// SPDX-License-Identifier: MIT
pragma solidity >=0.8.0 <0.9.0;

import "@openzeppelin/contracts/access/Ownable.sol";
import "./interfaces/IPriceFeed.sol";
import "./interfaces/IMint.sol";
import "./sAsset.sol";
import "./EUSD.sol";

contract Mint is Ownable, IMint{

    struct Asset {
        address token;
        uint minCollateralRatio;
        address priceFeed;
    }

    struct Position {
        uint idx;
        address owner;
        uint collateralAmount;
        address assetToken;
        uint assetAmount;
    }

    mapping(address => Asset) _assetMap;
    uint _currentPositionIndex;
    mapping(uint => Position) _idxPositionMap;
    address public collateralToken;
    

    constructor(address collateral) {
        collateralToken = collateral;
    }

    function registerAsset(address assetToken, uint minCollateralRatio, address priceFeed) external override onlyOwner {
        require(assetToken != address(0), "Invalid assetToken address");
        require(minCollateralRatio >= 1, "minCollateralRatio must be greater than 100%");
        require(_assetMap[assetToken].token == address(0), "Asset was already registered");
        
        _assetMap[assetToken] = Asset(assetToken, minCollateralRatio, priceFeed);
    }

    function getPosition(uint positionIndex) external view returns (address, uint, address, uint) {
        require(positionIndex < _currentPositionIndex, "Invalid index");
        Position storage position = _idxPositionMap[positionIndex];
        return (position.owner, position.collateralAmount, position.assetToken, position.assetAmount);
    }

    function getMintAmount(uint collateralAmount, address assetToken, uint collateralRatio) public view returns (uint) {
        Asset storage asset = _assetMap[assetToken];
        (int relativeAssetPrice, ) = IPriceFeed(asset.priceFeed).getLatestPrice();
        uint8 decimal = sAsset(assetToken).decimals();
        uint mintAmount = collateralAmount * (10 ** uint256(decimal)) / uint(relativeAssetPrice) / collateralRatio ;
        return mintAmount;
    }

    function checkRegistered(address assetToken) public view returns (bool) {
        return _assetMap[assetToken].token == assetToken;
    }

    /* TODO: implement your functions here */
    
    // Create a new position by transferring collateralAmount EUSD tokens from the message sender to the contract. 
    // Make sure the asset is registered and the input collateral ratio is not less than the asset MCR, 
    // then calculate the number of minted tokens to send to the message sender.
    function openPosition(uint collateralAmount, address assetToken, uint collateralRatio) external override {
        require(checkRegistered(assetToken), "Asset must be registered");
        require(collateralRatio >= _assetMap[assetToken].minCollateralRatio, "Input collateral ratio cannot be less than the asset MCR");
        
        Asset storage asset = _assetMap[assetToken];
        (int relativeAssetPrice, ) = IPriceFeed(asset.priceFeed).getLatestPrice();
        uint8 decimal = sAsset(assetToken).decimals();
        uint assetAmount = collateralAmount * (10 ** uint256(decimal)) / uint(relativeAssetPrice) /collateralRatio;

        _idxPositionMap[_currentPositionIndex] = Position(_currentPositionIndex, msg.sender, collateralAmount, assetToken, assetAmount);
        _currentPositionIndex += 1;

        sAsset(assetToken).mint(msg.sender, assetAmount);
        EUSD(collateralToken).transferFrom(msg.sender, address(this), collateralAmount);
    }

    // Close a position when the position owner calls this function. 
    // Transfer the sAsset tokens from the message sender to the contract and burn these tokens. 
    // Transfer EUSD tokens locked in the position to the message sender. 
    // Finally, delete the position at the given index.
    function closePosition(uint positionIndex) external override {
        require(positionIndex < _currentPositionIndex, "Invalid index");
        Position storage position = _idxPositionMap[positionIndex];
        require(position.owner == msg.sender, "Position must be closed by its owner");

        EUSD(collateralToken).transfer(msg.sender, position.collateralAmount);
        sAsset(position.assetToken).burn(msg.sender, position.assetAmount);
        delete _idxPositionMap[positionIndex];
    }

    // Add collateral amount of the position at the given index. 
    // Make sure the message sender owns the position and transfer deposited tokens from the sender to the contract.
    function deposit(uint positionIndex, uint collateralAmount) external override {
        require(positionIndex < _currentPositionIndex, "Invalid index");
        Position storage position = _idxPositionMap[positionIndex];
        require(position.owner == msg.sender, "Position must be owned by msg.sender");
        position.collateralAmount += collateralAmount;
        EUSD(collateralToken).transferFrom(msg.sender, address(this), collateralAmount);
    }

    // Withdraw collateral tokens from the position at the given index. 
    // Make sure the message sender owns the position and the collateral ratio won't go below the MCR. 
    // Transfer withdrawn tokens from the contract to the sender.
    function withdraw(uint positionIndex, uint withdrawAmount) external override {
        require(positionIndex < _currentPositionIndex, "Invalid index");
        Position storage position = _idxPositionMap[positionIndex];
        require(position.owner == msg.sender, "Position must be owned by msg.sender");
        uint currentCollateralAmount = position.collateralAmount;
        currentCollateralAmount -= withdrawAmount;
        require(currentCollateralAmount / position.assetAmount >= 2, "Collateral ratio cannot be less than the asset MCR");
        position.collateralAmount = currentCollateralAmount;
        EUSD(collateralToken).transfer(msg.sender, withdrawAmount);
    }

    // Mint more asset tokens from the position at the given index. 
    // Make sure the message sender owns the position and the collateral ratio won't go below the MCR.
    function mint(uint positionIndex, uint mintAmount) external override {
        require(positionIndex < _currentPositionIndex, "Invalid index");
        Position storage position = _idxPositionMap[positionIndex];
        require(position.owner == msg.sender, "Position must be owned by msg.sender");
        
        address assetToken = position.assetToken;
        Asset storage asset = _assetMap[assetToken];
        (int relativeAssetPrice, ) = IPriceFeed(asset.priceFeed).getLatestPrice();

        uint collateralRatio = (position.collateralAmount) / (position.assetAmount + mintAmount);
        require(collateralRatio >= _assetMap[position.assetToken].minCollateralRatio, "Collateral ratio cannot be less than the asset MCR");
        position.assetAmount += mintAmount;

        sAsset(assetToken).mint(msg.sender, mintAmount);
    }

    // Contract burns the given amount of asset tokens in the position. 
    // Make sure the message sender owns the position.
    function burn(uint positionIndex, uint burnAmount) external override {
        require(positionIndex < _currentPositionIndex, "Invalid index");
        Position storage position = _idxPositionMap[positionIndex];
        require(position.owner == msg.sender, "Position must be owned by msg.sender");
        sAsset(position.assetToken).burn(msg.sender, burnAmount);
        if (burnAmount > position.assetAmount) {
            position.assetAmount = 0;
        } else {
            position.assetAmount -= burnAmount;
        }
    }
}