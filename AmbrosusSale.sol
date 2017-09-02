//! Receipting contract. Just records who sent what.
//! By Parity Technologies, 2017.
//! Released under the Apache Licence 2.

pragma solidity ^0.4.16;

// ECR20 standard token interface
contract Token {
	event Transfer(address indexed from, address indexed to, uint256 value);
	event Approval(address indexed owner, address indexed spender, uint256 value);

	function balanceOf(address _owner) constant returns (uint256 balance);
	function transfer(address _to, uint256 _value) returns (bool success);
	function transferFrom(address _from, address _to, uint256 _value) returns (bool success);
	function approve(address _spender, uint256 _value) returns (bool success);
	function allowance(address _owner, address _spender) constant returns (uint256 remaining);
}

// Owner-specific contract interface
contract Owned {
	event NewOwner(address indexed old, address indexed current);

	modifier only_owner {
		require (msg.sender == owner);
		_;
	}

	address public owner = msg.sender;

	function setOwner(address _new) only_owner {
		NewOwner(owner, _new);
		owner = _new;
	}
}

// BasicCoin, ECR20 tokens that all belong to the owner for sending around
contract AmberToken is Token, Owned {
	// this is as basic as can be, only the associated balance & allowances
	struct Account {
		uint balance;
		mapping (address => uint) allowanceOf;

		uint tokensPerPhase;
		uint nextPhase;
	}

	event Minted(address indexed who, uint value);
	event MintedLocked(address indexed who, uint value);

	function AmberToken() {}

	// Mint a certain number of tokens.
	function mint(address _who, uint _value)
		only_owner
		public
	{
		accounts[_who].balance += _value;
		totalSupply += _value;
		Minted(_who, _value);
	}

	// Mint a certain number of tokens that are locked up.
	function mintLocked(address _who, uint _value)
		only_owner
		public
	{
		accounts[_who].tokensPerPhase += _value / UNLOCK_PHASES;
		totalSupply += _value;
		MintedLocked(_who, _value);
	}

	/// Finalise any minting operations. Resets the owner and causes normal tokens
	/// to be liquid. Also begins the countdown for locked-up tokens.
	function finalise()
		only_owner
		public
	{
		locked = false;
		owner = 0;
		phaseStart = now;
	}

	/// Return the current unlock-phase. Won't work until after the contract
	/// has `finalise()` called.
	function currentPhase()
		public
		constant
		returns (uint)
	{
		require (phaseStart > 0);
		uint p = (now - phaseStart) / PHASE_DURATION;
		return p > UNLOCK_PHASES ? UNLOCK_PHASES : p;
	}

	/// Unlock any now freeable tokens that are locked up for account `_who`.
	function unlockTokens(address _who)
		public
	{
		uint phase = currentPhase();
		uint tokens = accounts[_who].tokensPerPhase;
		uint nextPhase = accounts[_who].nextPhase;
		if (tokens > 0 && phase > nextPhase) {
			accounts[_who].balance += tokens * (phase - nextPhase);
			accounts[_who].nextPhase = phase;
		}
	}

	// Transfer tokens between accounts.
	function transfer(address _to, uint256 _value)
		when_owns(msg.sender, _value)
		when_liquid
		returns (bool)
	{
		Transfer(msg.sender, _to, _value);
		accounts[msg.sender].balance -= _value;
		accounts[_to].balance += _value;

		return true;
	}

	// Transfer via allowance.
	function transferFrom(address _from, address _to, uint256 _value)
		when_owns(_from, _value)
		when_has_allowance(_from, msg.sender, _value)
		when_liquid
		returns (bool)
	{
		Transfer(_from, _to, _value);
		accounts[_from].allowanceOf[msg.sender] -= _value;
		accounts[_from].balance -= _value;
		accounts[_to].balance += _value;

		return true;
	}

	// Approve allowances
	function approve(address _spender, uint256 _value)
		when_liquid
		returns (bool)
	{
		Approval(msg.sender, _spender, _value);
		accounts[msg.sender].allowanceOf[_spender] += _value;

		return true;
	}

	// Get the balance of a specific address.
	function balanceOf(address _who) constant returns (uint256) {
		return accounts[_who].balance;
	}

	// Available allowance
	function allowance(address _owner, address _spender)
		constant
		returns (uint256)
	{
		return accounts[_owner].allowanceOf[_spender];
	}

	// The balance should be available
	modifier when_owns(address _owner, uint _amount) {
		require (accounts[_owner].balance >= _amount);
		_;
	}

	// An allowance should be available
	modifier when_has_allowance(address _owner, address _spender, uint _amount) {
		require (accounts[_owner].allowanceOf[_spender] >= _amount);
		_;
	}

	// a value should be > 0
	modifier when_non_zero(uint _value) {
		require (_value > 0);
		_;
	}

	// Tokens must not be locked.
	modifier when_liquid {
		require (!locked);
		_;
	}

	// the base, tokens denoted in micros
	uint constant public base = 1000000000000000000;
	uint constant public DECIMALS = 18;

	// Can the tokens be transferred?
	bool public locked = true;

	// Phase information for slow-release tokens.
	uint public phaseStart = 0;
	uint public constant PHASE_DURATION = 180 days;
	uint public constant UNLOCK_PHASES = 4;

	// available token supply
	uint public totalSupply;

	// storage and mapping of all balances & allowances
	mapping (address => Account) accounts;
}

/// Will accept Ether "contributions" and record each both as a log and in a
/// queryable record.
contract AmbrosusSale {
	/// Constructor.
    function AmbrosusSale() {
		tokens = new AmberToken();
    }

	// Can only be called by the administrator.
    modifier only_admin { require (msg.sender == ADMINISTRATOR); _; }

	// The transaction params are valid for buying in.
    modifier is_valid_buyin { require (tx.gasprice <= MAX_BUYIN_GAS_PRICE && msg.value >= MIN_BUYIN_VALUE); _; }
	// Requires the hard cap to be respected given the desired amount for `buyin`.
	modifier is_under_cap_with(uint buyin) { require (buyin + saleRevenue <= MAX_REVENUE); _; }
	// Requires a valid signature to be given.
    modifier only_signed(address who, uint8 v, bytes32 r, bytes32 s) { require (ecrecover(sha3(SIGNING_PREFIX, who), v, r, s) == SIGNING_AUTHORITY); _; }

	/*
		Sale life cycle:
		1. Not yet started.
		2. Started, further purchases possible.
			a. Normal operation (next step can be 2b or 3)
			b. Paused (next step can be 2a or 3)
		3. Complete (equivalent to Allocation Lifecycle 2 & 3).
	*/

	// Can only be called by prior to the period (1).
    modifier only_before_period { require (now < BEGIN_TIME); _; }
	// Only does something if during the period (2).
    modifier when_during_period { if (now >= BEGIN_TIME && now < END_TIME && !isPaused) _; }
	// Can only be called during the period when not paused (2a).
    modifier only_during_period { require (now >= BEGIN_TIME && now < END_TIME && !isPaused); _; }
	// Can only be called during the period when paused (2b)
    modifier only_during_paused_period { require (now >= BEGIN_TIME && now < END_TIME && isPaused); _; }
	// Can only be called after the period (3).
    modifier only_after_sale { require (now >= END_TIME || saleRevenue >= MAX_REVENUE); _; }
	// Can only be called during the period when not paused (2a).
    modifier only_before_sale_end { require (now < END_TIME && saleRevenue < MAX_REVENUE); _; }

	/*
		Allocation life cycle:
		1. Uninitialised (sale not yet started/ended, equivalent to Sale Lifecycle 1 & 2).
		2. Initialised, not yet completed (further allocations possible).
		3. Completed (no further allocations possible).
	*/

	// Only when allocations have not yet been initialised (1).
	modifier when_allocations_uninitialised { require (!allocationsInitialised); _; }
	// Only when sufficient allocations remain for making this liquid allocation (2).
	modifier when_allocatable_liquid(uint amount) { require (liquidAllocatable >= amount); _; }
	// Only when sufficient allocations remain for making this locked allocation (2).
	modifier when_allocatable_locked(uint amount) { require (lockedAllocatable >= amount); _; }
	// Only when no further allocations are possible (3).
	modifier when_allocations_complete { require (allocationsInitialised && liquidAllocatable == 0 && lockedAllocatable == 0); _; }

	/// Note a pre-ICO sale.
	event Prepurchased(address indexed recipient, uint etherPaid, uint amberSold);
	/// Some contribution `amount` received from `recipient`.
    event Purchased(address indexed recipient, uint amount);
	/// Some contribution `amount` received from `recipient`.
    event SpecialPurchased(address indexed recipient, uint etherPaid, uint amberSold);
	/// Period paused abnormally.
    event Paused();
	/// Period restarted after abnormal halt.
    event Unpaused();
	/// Some contribution `amount` received from `recipient`.
    event Allocated(address indexed recipient, uint amount, bool liquid);

	/// Note a prepurchase that already happened.
	///
	/// Preconditions: !sale_started
	/// Writes {Tokens, Sale}
	function notePrepurchase(address _who, uint _etherPaid, uint _amberSold)
		only_admin
		only_before_period
		public
	{
		tokens.mint(_who, _amberSold);
		saleRevenue += _etherPaid;
		totalSold += _amberSold;
		Prepurchased(_who, _etherPaid, _amberSold);
	}

    /// Make a purchase from a privileged account. No KYC is required and a
	/// preferential buyin rate may be given.
	///
	/// Preconditions: !paused, sale_ongoing
	/// Postconditions: paused
	/// Writes {Tokens, Sale}
    function specialPurchase()
		only_before_period
		is_under_cap_with(msg.value)
		public
    {
        var bought = buyinReturn(msg.sender) * msg.value;
        require (bought > 0);   // be kind and don't punish the idiots.

        require (TREASURY.call.value(msg.value)());
        tokens.mint(msg.sender, bought);
        saleRevenue += msg.value;
		totalSold += bought;
        SpecialPurchased(msg.sender, msg.value, bought);
   }

	/// Let sender make a purchase to their account.
	///
	/// Preconditions: !paused, sale_ongoing
	/// Postconditions: ?!sale_ongoing
	/// Writes {Tokens, Sale}
    function purchase(uint8 v, bytes32 r, bytes32 s)
		only_signed(msg.sender, v, r, s)
		payable
		public
	{
        processPurchase(msg.sender);
    }

	/// Let sender make a standard purchase; AMR goes into another account.
	///
	/// Preconditions: !paused, sale_ongoing
	/// Postconditions: ?!sale_ongoing
	/// Writes {Tokens, Sale}
    function purchaseTo(address _recipient, uint8 v, bytes32 r, bytes32 s)
		only_signed(msg.sender, v, r, s)
		payable
		public
	{
		processPurchase(_recipient);
    }

	/// Receive a contribution from `_recipient`.
	///
	/// Preconditions: !paused, sale_ongoing
	/// Postconditions: ?!sale_ongoing
	/// Writes {Tokens, Sale}
    function processPurchase(address _recipient)
		only_during_period
		is_valid_buyin
		is_under_cap_with(msg.value)
		private
	{
        require (TREASURY.call.value(msg.value)());
        tokens.mint(_recipient, msg.value * STANDARD_BUYIN);
        saleRevenue += msg.value;
		totalSold += msg.value * STANDARD_BUYIN;
        Purchased(_recipient, msg.value);
    }

    /// Determine purchase price for a given address.
    /// This function is full of bare constants, mainly because that's how they're defined
    /// in the spec. Naming them would give little more clarity and just cause additional indirection.
    function buyinReturn(address _who)
        constant
        public
        returns (uint)
    {
        // Chinese exchanges.
        if (
            _who == CHINESE_EXCHANGE_1 || _who == CHINESE_EXCHANGE_2 ||
            _who == CHINESE_EXCHANGE_3 || _who == CHINESE_EXCHANGE_4
        )
            return CHINESE_EXCHANGE_BUYIN;

        // BTCSuisse tier 1
        if (_who == BTC_SUISSE_TIER_1)
            return STANDARD_BUYIN;
        // BTCSuisse tier 2
        if (_who == BTC_SUISSE_TIER_2)
            return TIER_2_BUYIN;
        // BTCSuisse tier 3
        if (_who == BTC_SUISSE_TIER_3)
            return TIER_3_BUYIN;
        // BTCSuisse tier 4
        if (_who == BTC_SUISSE_TIER_4)
            return TIER_4_BUYIN;

        return 0;
    }

	/// Halt the contribution period. Any attempt at contributing will fail.
	///
	/// Preconditions: !paused, sale_ongoing
	/// Postconditions: paused
	/// Writes {Paused}
    function pause()
		only_admin
		only_during_period
		public
	{
        isPaused = true;
        Paused();
    }

	/// Unhalt the contribution period.
	///
	/// Preconditions: paused
	/// Postconditions: !paused
	/// Writes {Paused}
    function unpause()
		only_admin
		only_during_paused_period
		public
	{
        isPaused = false;
        Unpaused();
    }

	/// Called once by anybody after the sale ends.
	/// Initialises the specific values (i.e. absolute token quantities) of the
	/// allowed liquid/locked allocations.
	///
	/// Preconditions: !allocations_initialised
	/// Postconditions: allocations_initialised, !allocations_complete
	/// Writes {Allocations}
	function initialiseAllocations()
		public
		only_after_sale
		when_allocations_uninitialised
	{
		allocationsInitialised = true;
		liquidAllocatable = LIQUID_ALLOCATION_PPM * totalSold / SALES_ALLOCATION_PPM;
		lockedAllocatable = LOCKED_ALLOCATION_PPM * totalSold / SALES_ALLOCATION_PPM;
	}

	/// Preallocate a liquid portion of tokens.
	/// Admin may call this to allocate a share of the liquid tokens.
	///
	/// Preconditions: allocations_initialised
	/// Postconditions: ?allocations_complete
	/// Writes {Allocations, Tokens}
	function allocateLiquid(address _who, uint _value)
	 	only_admin
		when_allocatable_liquid(_value)
		public
	{
		tokens.mint(_who, _value);
		liquidAllocatable -= _value;
        Allocated(_who, _value, true);
	}

	/// Preallocate a locked-up portion of tokens.
	/// Admin may call this to allocate a share of the locked tokens.
	///
	/// Preconditions: allocations_initialised
	/// Postconditions: ?allocations_complete
	/// Writes {Allocations, Tokens}
	function allocateLocked(address _who, uint _value)
	 	only_admin
		when_allocatable_locked(_value)
		public
	{
		tokens.mintLocked(_who, _value);
		lockedAllocatable -= _value;
        Allocated(_who, _value, false);
	}

	/// End of the sale and token allocation; retire this contract.
	/// Once called, no more tokens can be minted, basic tokens are now liquid.
	/// Anyone can call, but only once this contract can properly be retired.
	///
	/// Preconditions: allocations_complete
	/// Postconditions: liquid_tokens_transferable, this_is_dead
	/// Writes {Tokens}
    function finalise()
		when_allocations_complete
		public
	{
		tokens.finalise();
        suicide(TREASURY);
    }

	//////
	// STATE
	//////

	// How much is enough?
    uint public constant MIN_BUYIN_VALUE = 1;
	// Max gas price for buyins.
	uint public constant MAX_BUYIN_GAS_PRICE = 25000000000;
	// The exposed hard cap.
	uint public constant MAX_REVENUE = 315000 ether;
	// The signer who signs the message.
	address public constant SIGNING_AUTHORITY = 0x006E778F0fde07105C7adDc24b74b99bb4A89566;
	// The message to combine with the address and sign.
	string constant public SIGNING_PREFIX = "\x19Ethereum Signed Message:\n20";

	// The total share of tokens, expressed in PPM, allocated to pre-ICO and ICO.
	uint constant public SALES_ALLOCATION_PPM = 400000;
	// The total share of tokens, expressed in PPM, the admin may later allocate, as locked tokens.
	uint constant public LOCKED_ALLOCATION_PPM = 337000;
	// The total share of tokens, expressed in PPM, the admin may later allocate, as liquid tokens.
	uint constant public LIQUID_ALLOCATION_PPM = 263000;

	// Who can halt/unhalt/kill?
    address public constant ADMINISTRATOR = 0x006E778F0fde07105C7adDc24b74b99bb4A89566;
	// Who gets the stash?
    address public constant TREASURY = 0x006E778F0fde07105C7adDc24b74b99bb4A89566;
	// When does the contribution period begin?
    uint public constant BEGIN_TIME = now + 5 minutes;//1505304000
	// How long does the sale last for?
	uint public constant DURATION = 10 minutes;//30 days;
	// When does the period end?
    uint public constant END_TIME = BEGIN_TIME + DURATION;

	// The privileged buyin accounts.
	address public constant BTC_SUISSE_TIER_1 = 0x53B3D4f98fcb6f0920096fe1cCCa0E4327Da7a1D;
	address public constant BTC_SUISSE_TIER_2 = 0x642fDd12b1Dd27b9E19758F0AefC072dae7Ab996;
	address public constant BTC_SUISSE_TIER_3 = 0x64175446A1e3459c3E9D650ec26420BA90060d28;
	address public constant BTC_SUISSE_TIER_4 = 0xB17C2f9a057a2640309e41358a22Cf00f8B51626;
	address public constant CHINESE_EXCHANGE_1 = 0x36f548fAB37Fcd39cA8725B8fA214fcd784FE0A3;
	address public constant CHINESE_EXCHANGE_2 = 0x877Da872D223AB3D073Ab6f9B4bb27540E387C5F;
	address public constant CHINESE_EXCHANGE_3 = 0xCcC088ec38A4dbc15Ba269A176883F6ba302eD8d;
	address public constant CHINESE_EXCHANGE_4;

	// Tokens per eth for the various buy-in rates.
	uint public constant STANDARD_BUYIN = 1000;
	uint public constant TIER_2_BUYIN = 1111;
	uint public constant TIER_3_BUYIN = 1250;
	uint public constant TIER_4_BUYIN = 1429;
	uint public constant CHINESE_EXCHANGE_BUYIN = 1087;

	//////
	// State Subset: Allocations
	//
	// Invariants:
	// !allocationsInitialised ||
	//   (liquidAllocatable + tokens.liquidAllocated) / LIQUID_ALLOCATION_PPM == totalSold / SALES_ALLOCATION_PPM &&
	//   (lockedAllocatable + tokens.lockedAllocated) / LOCKED_ALLOCATION_PPM == totalSold / SALES_ALLOCATION_PPM
	//
	// allocationsInitialised || (now < END_TIME && saleRevenue < MAX_REVENUE)

	// Have post-sale token allocations been initialised?
	bool public allocationsInitialised = false;
	// How many liquid tokens may yet be allocated?
	uint public liquidAllocatable;
	// How many locked tokens may yet be allocated?
	uint public lockedAllocatable;

	//////
	// State Subset: Sale
	//
	// Invariants:
	// saleRevenue <= MAX_REVENUE

	// Total amount raised in both presale and sale, in Wei.
    uint public saleRevenue = 0;
	// Total amount minted in both presale and sale, in AMR * 10^-18.
    uint public totalSold = 0;

	//////
	// State Subset: Tokens

	// The contract which gets called whenever anything is received.
	AmberToken public tokens;

	//////
	// State Subset: Pause

	// Are contributions abnormally paused?
    bool public isPaused = false;
}
