var AmberToken = artifacts.require("AmberToken");

contract('ambertoken', function(accounts) {
	it("locked tokens are released correctly", function() {
		const ISSUED = 12;
		const OWNER = accounts[0];
		const VESTED = accounts[1];
		const increaseTime = addSeconds => {
			web3.currentProvider.send({jsonrpc: "2.0", method: "evm_increaseTime", params: [addSeconds], id: 0})
			web3.currentProvider.send({jsonrpc: "2.0", method: "evm_mine", params: [], id: 1})
		}
		var amber;
		var phaseDuration;
		var unlockPhases;
		var totalSupply;
		return AmberToken.new().then(function(instance) {
			amber = instance;
			return amber.PHASE_DURATION.call();
		}).then(function(duration) {
			phaseDuration = duration.toNumber();
			return amber.UNLOCK_PHASES.call();
		}).then(function(phases) {
			unlockPhases = phases.toNumber();
			amber.mintLocked(VESTED, ISSUED, {from: OWNER});
			return amber.totalSupply.call();
		}).then(function(supply) {
			totalSupply = supply.toNumber();
			assert.equal(totalSupply, ISSUED, "Total supply is not equal to issued tokens.");
			amber.finalise({from: OWNER});
			return amber.currentPhase.call();
		}).then(function(phase) {
			assert.equal(phase.toNumber(), 0, "Phase should start at 0.");
			amber.unlockTokens(VESTED, {from: OWNER});
			return amber.balanceOf.call(VESTED);
		}).then(function(initialBalance) {
			assert.equal(initialBalance.toNumber(), 0, "No tokens unlocked in phase 0.");
			increaseTime(phaseDuration);
			return amber.currentPhase.call();
		}).then(function(phase) {
			assert.equal(phase.toNumber(), 1, "Phase should progress to 1.");
			amber.unlockTokens(VESTED, {from: OWNER});
			return amber.balanceOf.call(VESTED);
		}).then(function(thenBalance) {
			assert.equal(thenBalance.toNumber(), ISSUED / unlockPhases, "1/4 tokens unlocked in phase 1.");
			// Wait through the remaining phases.
			increaseTime(phaseDuration * (unlockPhases - 1));
			return amber.currentPhase.call();
		}).then(function(phase) {
			assert.equal(phase.toNumber(), 4, "Phase should progress to 4.");
			amber.unlockTokens(VESTED, {from: OWNER});
			return amber.balanceOf.call(VESTED);
		}).then(function(thenBalance) {
			assert.equal(thenBalance.toNumber(), totalSupply, "Whole supply released.");
			// Wait a bunch after the last phase.
			increaseTime(phaseDuration * 2);
			return amber.currentPhase.call();
		}).then(function(phase) {
			assert.equal(phase.toNumber(), unlockPhases, "Phase should stay at 4.");
			amber.unlockTokens(VESTED, {from: OWNER});
			return amber.balanceOf.call(VESTED);
		}).then(function(thenBalance) {
			assert.equal(thenBalance.toNumber(), totalSupply, "No more tokens released.");
		});
	});
});
