// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IERC1155} from "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";
import {ERC1155Holder} from "@openzeppelin/contracts/token/ERC1155/utils/ERC1155Holder.sol";
import {IERC2981} from "@openzeppelin/contracts/interfaces/IERC2981.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title FOMO Arena Market: fixed-price listings and live auctions for FOMO cards.
/// @notice Cards are escrowed in this contract while listed. Every sale pays:
///         platform fee (fixed at deploy, max 10%) + creator royalty (ERC-2981 of the card contract) to their receivers,
///         the rest to the seller. Outbid bidders get their ETH back (pushed, or claimable via withdraw()).
///         The owner can pause NEW listings/bids but can never touch escrowed cards or funds.
contract FomoMarket is ERC1155Holder, Ownable, Pausable, ReentrancyGuard {
    IERC1155 public immutable cards;
    uint16 public immutable feeBps;          // platform fee, immutable
    address public feeTo;                    // platform fee receiver
    uint256 public constant MIN_STEP_BPS = 500;       // next bid >= +5%
    uint256 public constant EXTEND = 5 minutes;       // anti-sniping
    uint256 public constant MAX_DURATION = 14 days;

    struct Listing {
        address seller;
        uint96 id;          // token id
        uint64 amount;      // number of copies sold as one lot
        uint64 end;         // 0 = fixed price
        uint128 price;      // fixed price or auction reserve (minimum first bid)
        address bidder;     // highest bidder
        uint128 bid;        // highest bid
        bool active;
    }

    uint256 public nextId = 1;
    mapping(uint256 => Listing) public listings;
    mapping(address => uint256) public credit; // failed pushes, claim with withdraw()

    event Listed(uint256 indexed lid, address indexed seller, uint256 id, uint256 amount, uint256 price, uint256 end);
    event Bid(uint256 indexed lid, address indexed bidder, uint256 amount, uint256 end);
    event Sold(uint256 indexed lid, address indexed buyer, uint256 price, uint256 fee, uint256 royalty);
    event Cancelled(uint256 indexed lid);

    constructor(address cards_, uint16 feeBps_, address feeTo_) Ownable(msg.sender) {
        require(feeBps_ <= 1000, "fee>10%");
        require(feeTo_ != address(0), "feeTo");
        cards = IERC1155(cards_); feeBps = feeBps_; feeTo = feeTo_;
    }

    function setFeeTo(address a) external onlyOwner { require(a != address(0)); feeTo = a; }
    function pause() external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }

    /// @param duration 0 for fixed price, else auction length in seconds (max 14 days)
    function list(uint256 id, uint256 amount, uint256 price, uint256 duration) external whenNotPaused nonReentrant returns (uint256 lid) {
        require(amount > 0 && amount <= type(uint64).max, "amount");
        require(price > 0 && price <= type(uint128).max, "price");
        require(duration <= MAX_DURATION, "duration");
        require(id <= type(uint96).max, "id");
        lid = nextId++;
        uint64 end = duration == 0 ? 0 : uint64(block.timestamp + duration);
        listings[lid] = Listing(msg.sender, uint96(id), uint64(amount), end, uint128(price), address(0), 0, true);
        cards.safeTransferFrom(msg.sender, address(this), id, amount, "");
        emit Listed(lid, msg.sender, id, amount, price, end);
    }

    /// @notice Buy a fixed-price listing. Exact price only.
    function buy(uint256 lid) external payable whenNotPaused nonReentrant {
        Listing storage l = listings[lid];
        require(l.active && l.end == 0, "not for sale");
        require(msg.value == l.price, "wrong payment");
        require(msg.sender != l.seller, "own listing");
        l.active = false;
        _settle(lid, l, msg.sender, msg.value);
    }

    /// @notice Bid on a live auction. ETH is held here; you are refunded automatically if outbid.
    function bid(uint256 lid) external payable whenNotPaused nonReentrant {
        Listing storage l = listings[lid];
        require(l.active && l.end != 0, "not auction");
        require(block.timestamp < l.end, "ended");
        require(msg.sender != l.seller, "own listing");
        uint256 min = l.bid == 0 ? l.price : uint256(l.bid) * (10000 + MIN_STEP_BPS) / 10000;
        require(msg.value >= min && msg.value <= type(uint128).max, "bid too low");
        address prev = l.bidder; uint256 prevBid = l.bid;
        l.bidder = msg.sender; l.bid = uint128(msg.value);
        if (l.end - block.timestamp < EXTEND) l.end = uint64(block.timestamp + EXTEND);
        if (prev != address(0)) _pay(prev, prevBid);
        emit Bid(lid, msg.sender, msg.value, l.end);
    }

    /// @notice Anyone can finalize an ended auction. No bids: card goes back to the seller.
    function settle(uint256 lid) external nonReentrant {
        Listing storage l = listings[lid];
        require(l.active && l.end != 0, "not auction");
        require(block.timestamp >= l.end, "live");
        l.active = false;
        if (l.bidder == address(0)) {
            cards.safeTransferFrom(address(this), l.seller, l.id, l.amount, "");
            emit Cancelled(lid);
        } else {
            _settle(lid, l, l.bidder, l.bid);
        }
    }

    /// @notice Seller cancels a fixed listing anytime, or an auction that has no bids yet.
    function cancel(uint256 lid) external nonReentrant {
        Listing storage l = listings[lid];
        require(l.active && l.seller == msg.sender, "not yours");
        require(l.bidder == address(0), "has bids");
        l.active = false;
        cards.safeTransferFrom(address(this), l.seller, l.id, l.amount, "");
        emit Cancelled(lid);
    }

    function withdraw() external nonReentrant {
        uint256 a = credit[msg.sender]; require(a > 0, "none");
        credit[msg.sender] = 0;
        (bool ok,) = msg.sender.call{value: a}(""); require(ok, "send");
    }

    /// @notice What a sale at `price` pays to each party.
    function quote(uint256 id, uint256 price) public view returns (uint256 fee, address royaltyTo, uint256 royalty, uint256 toSeller) {
        fee = price * feeBps / 10000;
        try IERC2981(address(cards)).royaltyInfo(id, price) returns (address r, uint256 amt) {
            if (r != address(0) && amt <= price - fee) { royaltyTo = r; royalty = amt; }
        } catch {}
        toSeller = price - fee - royalty;
    }

    function _settle(uint256 lid, Listing storage l, address buyer, uint256 price) internal {
        (uint256 fee, address rTo, uint256 royalty, uint256 toSeller) = quote(l.id, price);
        cards.safeTransferFrom(address(this), buyer, l.id, l.amount, "");
        if (fee > 0) _pay(feeTo, fee);
        if (royalty > 0) _pay(rTo, royalty);
        _pay(l.seller, toSeller);
        emit Sold(lid, buyer, price, fee, royalty);
    }

    function _pay(address to, uint256 a) internal {
        bool ok;
        assembly { ok := call(30000, to, a, 0, 0, 0, 0) } // no returndata copy (return-bomb safe)
        if (!ok) credit[to] += a;
    }
}
