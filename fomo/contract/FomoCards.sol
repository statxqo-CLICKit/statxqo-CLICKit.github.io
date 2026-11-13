// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {ERC1155} from "@openzeppelin/contracts/token/ERC1155/ERC1155.sol";
import {ERC1155Supply} from "@openzeppelin/contracts/token/ERC1155/extensions/ERC1155Supply.sol";
import {ERC2981} from "@openzeppelin/contracts/token/common/ERC2981.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title FOMO Web5 NFT Arena cards
/// @notice Token id = star tier (1..7). Fixed-price mints: the buyer picks the exact tier (no blind boxes, no randomness).
///         Evolve burns 3 cards of tier n and mints 1 of tier n+1. Collectible game items only: not an investment.
contract FomoCards is ERC1155, ERC1155Supply, ERC2981, Ownable, Pausable, ReentrancyGuard {
    string public constant name = "FOMO Arena Cards";
    string public constant symbol = "FOMO";
    uint8 public constant MAX_TIER = 7;
    uint256 public constant MAX_PER_TX = 20;

    address payable public payout;
    mapping(uint256 => uint256) public price; // tier => wei; 0 = not for sale

    event Minted(address indexed to, uint256 indexed tier, uint256 amount, uint256 paid);
    event Evolved(address indexed who, uint256 indexed fromTier, uint256 times);
    event PriceSet(uint256 indexed tier, uint256 price);
    event PayoutSet(address payout);

    error BadTier(); error BadAmount(); error WrongPayment(); error NotForSale(); error TransferFailed();

    constructor(address payable _payout, string memory uri_) ERC1155(uri_) Ownable(msg.sender) {
        payout = _payout;
        _setDefaultRoyalty(_payout, 500); // 5%
        price[1] = 0.01 ether; emit PriceSet(1, 0.01 ether);
        price[3] = 0.03 ether; emit PriceSet(3, 0.03 ether);
        price[7] = 0.07 ether; emit PriceSet(7, 0.07 ether);
    }

    function mint(uint256 tier, uint256 amount) external payable whenNotPaused nonReentrant {
        if (tier == 0 || tier > MAX_TIER) revert BadTier();
        if (amount == 0 || amount > MAX_PER_TX) revert BadAmount();
        uint256 p = price[tier];
        if (p == 0) revert NotForSale();
        if (msg.value != p * amount) revert WrongPayment();
        _mint(msg.sender, tier, amount, "");
        emit Minted(msg.sender, tier, amount, msg.value);
        (bool ok, ) = payout.call{value: msg.value}("");
        if (!ok) revert TransferFailed();
    }

    /// @notice Burn 3*times cards of `fromTier`, mint `times` cards of fromTier+1. Free (gas only).
    function evolve(uint256 fromTier, uint256 times) external whenNotPaused {
        if (fromTier == 0 || fromTier >= MAX_TIER) revert BadTier();
        if (times == 0 || times > MAX_PER_TX) revert BadAmount();
        _burn(msg.sender, fromTier, 3 * times);
        _mint(msg.sender, fromTier + 1, times, "");
        emit Evolved(msg.sender, fromTier, times);
    }

    // --- owner
    function setPrice(uint256 tier, uint256 p) external onlyOwner { if (tier == 0 || tier > MAX_TIER) revert BadTier(); price[tier] = p; emit PriceSet(tier, p); }
    function setPayout(address payable p) external onlyOwner { payout = p; _setDefaultRoyalty(p, 500); emit PayoutSet(p); }
    function setURI(string calldata u) external onlyOwner { _setURI(u); }
    function pause() external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }
    /// @notice Sends any stray ETH to payout.
    function sweep() external { (bool ok, ) = payout.call{value: address(this).balance}(""); if (!ok) revert TransferFailed(); }

    function uri(uint256 id) public view override returns (string memory) {
        return string.concat(super.uri(id), _toString(id), ".json");
    }
    function _toString(uint256 v) internal pure returns (string memory s) { if (v == 0) return "0"; uint256 j=v; uint256 l; while (j!=0){l++; j/=10;} bytes memory b=new bytes(l); while (v!=0){ l--; b[l]=bytes1(uint8(48+v%10)); v/=10;} s=string(b); }

    function _update(address from, address to, uint256[] memory ids, uint256[] memory values) internal override(ERC1155, ERC1155Supply) { super._update(from, to, ids, values); }
    function supportsInterface(bytes4 i) public view override(ERC1155, ERC2981) returns (bool) { return super.supportsInterface(i); }
}
