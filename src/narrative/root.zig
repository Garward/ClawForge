//! Public API for the standalone Narrative Studio subsystem.

pub const domain = @import("domain/root.zig");
pub const embedding = @import("embedding_gateway.zig");
pub const Runtime = @import("runtime.zig").Runtime;
pub const Service = @import("application/service.zig").Service;

pub const Story = domain.Story;
pub const CreateStory = domain.CreateStory;
pub const ModelProfile = domain.ModelProfile;
pub const Record = domain.Record;
pub const Node = domain.Node;
pub const CreateNode = domain.CreateNode;
pub const ProseBlock = domain.ProseBlock;
pub const ProseDocument = domain.ProseDocument;
pub const ProsePatch = domain.ProsePatch;
pub const AuthorMessage = domain.AuthorMessage;
pub const Job = domain.Job;
pub const DecisionProposal = domain.DecisionProposal;
