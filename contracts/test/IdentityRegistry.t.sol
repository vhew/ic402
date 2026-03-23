// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/IdentityRegistry.sol";

contract IdentityRegistryTest is Test {
    IdentityRegistry public registry;

    function setUp() public {
        registry = new IdentityRegistry();
    }

    function test_deploys_with_zero_agents() public view {
        assertEq(registry.totalAgents(), 0);
        assertEq(registry.nextTokenId(), 0);
    }

    function test_register_creates_agent() public {
        string[] memory skills = new string[](2);
        skills[0] = "summarize";
        skills[1] = "translate";

        string[] memory domains = new string[](1);
        domains[0] = "content";

        uint256 tokenId = registry.register(
            "TestAgent",
            "A test agent",
            "https://example.com/api",
            skills,
            domains,
            true
        );

        assertEq(tokenId, 0);
        assertEq(registry.totalAgents(), 1);
        assertEq(registry.ownerOf(tokenId), address(this));

        IdentityRegistry.AgentCard memory card = registry.getAgent(tokenId);
        assertEq(card.name, "TestAgent");
        assertEq(card.description, "A test agent");
        assertEq(card.endpoint, "https://example.com/api");
        assertEq(card.skills.length, 2);
        assertEq(card.skills[0], "summarize");
        assertEq(card.domains[0], "content");
        assertTrue(card.x402Support);
    }

    function test_register_multiple_agents() public {
        string[] memory skills = new string[](0);
        string[] memory domains = new string[](0);

        uint256 id0 = registry.register("Agent0", "First", "https://a.com", skills, domains, false);
        uint256 id1 = registry.register("Agent1", "Second", "https://b.com", skills, domains, true);

        assertEq(id0, 0);
        assertEq(id1, 1);
        assertEq(registry.totalAgents(), 2);
    }

    function test_agentsByOwner_returns_owned_tokens() public {
        string[] memory skills = new string[](0);
        string[] memory domains = new string[](0);

        registry.register("Agent0", "First", "https://a.com", skills, domains, false);
        registry.register("Agent1", "Second", "https://b.com", skills, domains, true);

        uint256[] memory owned = registry.agentsByOwner(address(this));
        assertEq(owned.length, 2);
        assertEq(owned[0], 0);
        assertEq(owned[1], 1);
    }

    function test_getAgent_reverts_for_nonexistent() public {
        vm.expectRevert("Agent not found");
        registry.getAgent(999);
    }
}
