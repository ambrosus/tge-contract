var MultiCertifier = artifacts.require("MultiCertifier");
var AmbrosusSale = artifacts.require("AmbrosusSale");

module.exports = function(deployer) {
	deployer.deploy(MultiCertifier).then(function() {
		return deployer.deploy(AmbrosusSale, MultiCertifier.address);
	});
};
