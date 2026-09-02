//! Narrative domain data-transfer types.

pub const story = @import("story.zig");
pub const record = @import("record.zig");
pub const node = @import("node.zig");
pub const prose = @import("prose.zig");
pub const author_room = @import("author_room.zig");
pub const job = @import("job.zig");
pub const proposal = @import("proposal.zig");

pub const Story = story.Story;
pub const CreateStory = story.CreateStory;
pub const ModelProfile = story.ModelProfile;
pub const Record = record.Record;
pub const required_story_record_types = record.required_story_record_types;
pub const Node = node.Node;
pub const CreateNode = node.CreateNode;
pub const ProseBlock = prose.ProseBlock;
pub const ProseDocument = prose.ProseDocument;
pub const ProsePatch = prose.ProsePatch;
pub const AuthorMessage = author_room.AuthorMessage;
pub const Job = job.Job;
pub const DecisionProposal = proposal.DecisionProposal;
pub const DocumentChange = proposal.DocumentChange;
