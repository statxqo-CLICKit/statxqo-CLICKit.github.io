// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {ERC1155} from "@openzeppelin/contracts/token/ERC1155/ERC1155.sol";
import {ERC1155Supply} from "@openzeppelin/contracts/token/ERC1155/extensions/ERC1155Supply.sol";
import {ERC2981} from "@openzeppelin/contracts/token/common/ERC2981.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Base64} from "@openzeppelin/contracts/utils/Base64.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";

/// @title FOMO Web5 NFT Arena cards (v2)
/// @notice Card id = star tier 1..7. Add-on ids 101..104.
///  - Paid mints: buyer picks the exact tier at a fixed price hard-coded below. Mint, payment
///    forwarding and delivery happen in one transaction; if any step fails the whole tx reverts.
///  - Art and metadata are fully on-chain (art bytes written once at deploy, no setter). The owner
///    cannot change art, metadata, prices or caps.
///  - Per-tier supply caps are constants and enforced on every mint (paid or evolve).
///  - Evolve: burn 3 of tier n, receive 1 of tier n+1 (gas only).
///  - Early-adopter bonus: FREE, one per wallet, first BONUS_MAX wallets. Every claimer gets an
///    add-on; only its rarity is random, drawn from a future blockhash (commit then reveal), never
///    a server roll. Odds: Aura 55%, Neon Frame 30%, Star Boost 12%, Halo of Seven 3%.
///    Paid mints never affect bonus odds, and add-ons never replace or reduce a paid card.
///  Collectible game items. Not an investment. No returns promised.
contract FomoCards is ERC1155, ERC1155Supply, ERC2981, Ownable, Pausable, ReentrancyGuard {
    using Strings for uint256;

    string public constant name = "FOMO Arena Cards";
    string public constant symbol = "FOMO";
    uint256 public constant MAX_TIER = 7;
    uint256 public constant MAX_PER_TX = 20;

    // Fixed prices (wei), set once at deploy and immutable forever after. Tiers 2,4,5,6 are not
    // sold directly (reach them by evolving). Mainnet deploy: 0.01 / 0.03 / 0.07 ETH.
    uint256 public immutable PRICE_1;
    uint256 public immutable PRICE_3;
    uint256 public immutable PRICE_7;

    // Add-ons
    uint256 public constant ADDON_AURA = 101;   // 55%
    uint256 public constant ADDON_FRAME = 102;  // 30%
    uint256 public constant ADDON_BOOST = 103;  // 12%
    uint256 public constant ADDON_HALO = 104;   // 3%
    string public constant BONUS_ODDS = "Aura 55%, Neon Frame 30%, Star Boost 12%, Halo of Seven 3%";
    uint256 public constant REVEAL_DELAY = 2; // blocks

    address payable public payout;
    address[3] public art; // SSTORE2-style data contracts: knight, cat, skull (JPEG bytes)

    uint256 public bonusMax;      // early bonus slots (starts 500)
    uint256 public bonusClaimed;  // slots taken
    mapping(address => uint256) public bonusTarget;  // block whose hash decides rarity (0 = none)
    mapping(address => uint256) public bonusAddon;   // add-on id received (0 = not revealed)

    event Minted(address indexed to, uint256 indexed tier, uint256 amount, uint256 paid);
    event Evolved(address indexed who, uint256 indexed fromTier, uint256 times);
    event BonusCommitted(address indexed who, uint256 targetBlock);
    event BonusRevealed(address indexed who, uint256 indexed addonId, uint256 roll);
    event PayoutSet(address payout);
    event BonusMaxSet(uint256 bonusMax);

    error BadTier(); error BadAmount(); error WrongPayment(); error NotForSale(); error TransferFailed();
    error SoldOut(); error BonusTaken(); error NoBonusLeft(); error NotCommitted(); error TooEarly(); error AlreadyRevealed();

    constructor(address payable _payout, uint256 p1, uint256 p3, uint256 p7, bytes memory knight, bytes memory cat, bytes memory skull)
        ERC1155("") Ownable(msg.sender)
    {
        require(_payout != address(0), "zero payout");
        payout = _payout;
        PRICE_1 = p1; PRICE_3 = p3; PRICE_7 = p7;
        _setDefaultRoyalty(_payout, 500); // 5%
        art[0] = _store(knight); art[1] = _store(cat); art[2] = _store(skull);
        bonusMax = 500;
    }

    // ---------- pricing & caps (constants)
    function priceOf(uint256 tier) public view returns (uint256) {
        if (tier == 1) return PRICE_1;
        if (tier == 3) return PRICE_3;
        if (tier == 7) return PRICE_7;
        return 0;
    }
    function capOf(uint256 id) public pure returns (uint256) {
        if (id == 1) return 10000; if (id == 2) return 5000; if (id == 3) return 3000;
        if (id == 4) return 1500;  if (id == 5) return 700;  if (id == 6) return 300;
        if (id == 7) return 777;
        if (id >= ADDON_AURA && id <= ADDON_HALO) return type(uint256).max; // bounded by bonusMax
        return 0;
    }
    function remaining(uint256 id) external view returns (uint256) { return capOf(id) - totalSupply(id); }
    function bonusLeft() external view returns (uint256) { return bonusMax > bonusClaimed ? bonusMax - bonusClaimed : 0; }

    // ---------- paid mint (atomic: pay -> forward -> deliver, or revert all)
    function mint(uint256 tier, uint256 amount) external payable whenNotPaused nonReentrant {
        if (tier == 0 || tier > MAX_TIER) revert BadTier();
        if (amount == 0 || amount > MAX_PER_TX) revert BadAmount();
        uint256 p = priceOf(tier);
        if (p == 0) revert NotForSale();
        if (msg.value != p * amount) revert WrongPayment();
        _mintCapped(msg.sender, tier, amount);
        (bool ok, ) = payout.call{value: msg.value}("");
        if (!ok) revert TransferFailed();
        emit Minted(msg.sender, tier, amount, msg.value);
    }

    // ---------- evolve
    function evolve(uint256 fromTier, uint256 times) external whenNotPaused nonReentrant {
        if (fromTier == 0 || fromTier >= MAX_TIER) revert BadTier();
        if (times == 0 || times > MAX_PER_TX) revert BadAmount();
        _burn(msg.sender, fromTier, 3 * times);
        _mintCapped(msg.sender, fromTier + 1, times);
        emit Evolved(msg.sender, fromTier, times);
    }

    // ---------- free early-adopter bonus
    function claimBonus() external whenNotPaused {
        if (bonusTarget[msg.sender] != 0) revert BonusTaken();
        if (bonusClaimed >= bonusMax) revert NoBonusLeft();
        bonusClaimed++;
        uint256 t = block.number + REVEAL_DELAY;
        bonusTarget[msg.sender] = t;
        emit BonusCommitted(msg.sender, t);
    }

    /// @notice Anyone may reveal for `who`. If the target block is older than 256 blocks its hash is
    ///  gone, so the claim is re-committed to a new future block (the slot is kept).
    function revealBonus(address who) external nonReentrant {
        uint256 t = bonusTarget[who];
        if (t == 0) revert NotCommitted();
        if (bonusAddon[who] != 0) revert AlreadyRevealed();
        if (block.number <= t) revert TooEarly();
        bytes32 h = blockhash(t);
        if (h == bytes32(0)) {
            uint256 nt = block.number + REVEAL_DELAY;
            bonusTarget[who] = nt;
            emit BonusCommitted(who, nt);
            return;
        }
        uint256 roll = uint256(keccak256(abi.encodePacked(h, who, address(this)))) % 100;
        uint256 id = roll < 55 ? ADDON_AURA : roll < 85 ? ADDON_FRAME : roll < 97 ? ADDON_BOOST : ADDON_HALO;
        bonusAddon[who] = id;
        _mint(who, id, 1, "");
        emit BonusRevealed(who, id, roll);
    }

    // ---------- owner (cannot touch art, prices, caps or balances)
    function setPayout(address payable p) external onlyOwner { require(p != address(0), "zero payout"); payout = p; _setDefaultRoyalty(p, 500); emit PayoutSet(p); }
    function setBonusMax(uint256 m) external onlyOwner { require(m >= bonusClaimed, "below claimed"); bonusMax = m; emit BonusMaxSet(m); }
    function pause() external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }

    // ---------- on-chain metadata
    function uri(uint256 id) public view override returns (string memory) {
        string memory json;
        if (id >= 1 && id <= MAX_TIER) json = _cardJson(id);
        else if (id >= ADDON_AURA && id <= ADDON_HALO) json = _addonJson(id);
        else revert BadTier();
        return string.concat("data:application/json;base64,", Base64.encode(bytes(json)));
    }

    function _tierName(uint256 t) internal pure returns (string memory) {
        return ["", "Common", "Uncommon", "Rare", "Epic", "Legendary", "Mythic", "God Tier"][t];
    }
    function _cardName(uint256 t) internal pure returns (string memory) {
        return ["", "Iron Sentinel", "Frost Sentinel", "Neon Prowler", "Void Prowler", "Astral Warlord", "Blood Warlord", "Horned Overlord"][t];
    }
    function _cardJson(uint256 t) internal view returns (string memory) {
        uint256 a = t <= 2 ? 0 : t <= 4 ? 1 : 2;
        string[8] memory hue = ["0", "0", "160", "0", "60", "190", "260", "0"];
        string[8] memory c1 = ["", "#2bd47a", "#3ef0ff", "#c04bff", "#ff4fd8", "#3ef0ff", "#ff4fd8", "#ffc531"];
        string[8] memory c2 = ["", "#0b5a6a", "#1a3a9a", "#3ef0ff", "#6a1aff", "#c04bff", "#ff3355", "#ff5a00"];
        string memory img = string.concat("data:image/jpeg;base64,", Base64.encode(_read(art[a])));
        string memory svg = string.concat(
            '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 260 300"><defs><linearGradient id="g" x1="0" y1="0" x2="1" y2="1"><stop offset="0" stop-color="', c1[t],
            '"/><stop offset="1" stop-color="', c2[t], '"/></linearGradient><filter id="h"><feColorMatrix type="hueRotate" values="', hue[t],
            '"/></filter></defs><rect width="260" height="300" rx="18" fill="url(#g)"/><image x="10" y="10" width="240" height="253" href="', img,
            '" filter="url(#h)"/><rect x="10" y="262" width="240" height="30" rx="8" fill="#000c"/><text x="130" y="283" font-family="sans-serif" font-size="15" font-weight="700" fill="#ffc531" text-anchor="middle">',
            t.toString(), unicode"★ ", _tierName(t), "</text></svg>"
        );
        return string.concat(
            '{"name":"', _cardName(t), unicode" · ", t.toString(), unicode"★ ", _tierName(t),
            '","description":"FOMO Web5 NFT Arena card. Collectible game item. Not an investment; no returns promised. Art and metadata are stored fully on-chain and cannot be changed.","image":"data:image/svg+xml;base64,',
            Base64.encode(bytes(svg)),
            '","attributes":[{"trait_type":"Stars","value":', t.toString(), '},{"trait_type":"Tier","value":"', _tierName(t),
            '"},{"trait_type":"Supply cap","value":', capOf(t).toString(), "}]}"
        );
    }
    function _addonJson(uint256 id) internal pure returns (string memory) {
        uint256 i = id - ADDON_AURA;
        string[4] memory n = ["Aura", "Neon Frame", "Star Boost", "Halo of Seven"];
        string[4] memory r = ["Common", "Rare", "Epic", "Legendary"];
        string[4] memory c = ["#3ef0ff", "#c04bff", "#ff4fd8", "#ffc531"];
        string memory svg = string.concat(
            '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 260 300"><rect width="260" height="300" rx="18" fill="#07021a"/><circle cx="130" cy="130" r="80" fill="none" stroke="', c[i],
            '" stroke-width="10" opacity=".9"/><circle cx="130" cy="130" r="55" fill="', c[i], '" opacity=".25"/><text x="130" y="140" font-family="sans-serif" font-size="30" fill="#fff" text-anchor="middle">',
            unicode"✦", '</text><text x="130" y="250" font-family="sans-serif" font-size="20" font-weight="700" fill="', c[i], '" text-anchor="middle">', n[i],
            '</text><text x="130" y="276" font-family="sans-serif" font-size="13" fill="#ccc" text-anchor="middle">Early adopter add-on</text></svg>'
        );
        return string.concat(
            '{"name":"', n[i], " (", r[i], ' add-on)","description":"Free FOMO early-adopter add-on. Rarity drawn on-chain from a future blockhash. Odds: ', BONUS_ODDS,
            '. Not an investment.","image":"data:image/svg+xml;base64,', Base64.encode(bytes(svg)),
            '","attributes":[{"trait_type":"Add-on","value":"', n[i], '"},{"trait_type":"Rarity","value":"', r[i], '"}]}'
        );
    }

    // ---------- internals
    function _mintCapped(address to, uint256 id, uint256 amount) internal {
        if (totalSupply(id) + amount > capOf(id)) revert SoldOut();
        _mint(to, id, amount, "");
    }
    function _store(bytes memory data) internal returns (address p) {
        bytes memory code = abi.encodePacked(hex"00", data); // leading STOP: never executable
        bytes memory init = abi.encodePacked(hex"63", uint32(code.length), hex"80600e6000396000f3", code);
        assembly { p := create(0, add(init, 32), mload(init)) }
        require(p != address(0), "store failed");
    }
    function _read(address p) internal view returns (bytes memory data) {
        uint256 size; assembly { size := extcodesize(p) }
        data = new bytes(size - 1);
        assembly { extcodecopy(p, add(data, 32), 1, sub(size, 1)) }
    }
    function _update(address from, address to, uint256[] memory ids, uint256[] memory values)
        internal override(ERC1155, ERC1155Supply) { super._update(from, to, ids, values); }
    function supportsInterface(bytes4 i) public view override(ERC1155, ERC2981) returns (bool) { return super.supportsInterface(i); }
}
