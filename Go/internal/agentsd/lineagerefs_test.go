package agentsd

import (
	"github.com/alexec/agents/Go/internal/lineage"
	"github.com/alexec/agents/Go/wire"
)

// sessionNode is a session's node in a test whose folder has no origin: agents:session:#<id>.
func sessionNode(id wire.UUID) wire.LineageNode { return lineage.SessionNode("", string(id)) }
