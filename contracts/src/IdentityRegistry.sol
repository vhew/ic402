// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.20;

/// @title IdentityRegistry — ERC-8004 Agent Discovery
/// @notice Minimal on-chain registry for AI agent discovery.
///         Agents register their capabilities (skills, domains, x402 support)
///         and other agents can query the registry to find services.
///
///         Each registration mints a token ID (not a full ERC-721 — no transfer/approve).
///         This is a hackathon-scoped contract; a production version would implement
///         the full ERC-721 interface and add access control.
contract IdentityRegistry {
    struct AgentCard {
        string name;
        string description;
        string endpoint;
        string[] skills;
        string[] domains;
        bool x402Support;
    }

    uint256 public nextTokenId;
    mapping(uint256 => AgentCard) private _agents;
    mapping(uint256 => address) public ownerOf;
    mapping(address => uint256[]) private _tokensByOwner;

    event AgentRegistered(
        uint256 indexed tokenId,
        address indexed owner,
        string name,
        string endpoint,
        bool x402Support
    );

    /// @notice Register an agent and mint a token ID.
    function register(
        string calldata name,
        string calldata description,
        string calldata endpoint,
        string[] calldata skills,
        string[] calldata domains,
        bool x402Support
    ) external returns (uint256) {
        uint256 tokenId = nextTokenId++;
        _agents[tokenId] = AgentCard(name, description, endpoint, skills, domains, x402Support);
        ownerOf[tokenId] = msg.sender;
        _tokensByOwner[msg.sender].push(tokenId);
        emit AgentRegistered(tokenId, msg.sender, name, endpoint, x402Support);
        return tokenId;
    }

    /// @notice Get an agent's card by token ID.
    function getAgent(uint256 tokenId) external view returns (AgentCard memory) {
        require(ownerOf[tokenId] != address(0), "Agent not found");
        return _agents[tokenId];
    }

    /// @notice List all token IDs owned by an address.
    function agentsByOwner(address owner) external view returns (uint256[] memory) {
        return _tokensByOwner[owner];
    }

    /// @notice Total number of registered agents.
    function totalAgents() external view returns (uint256) {
        return nextTokenId;
    }
}
