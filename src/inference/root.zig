//! Shared model-invocation contracts used by chat and Narrative runtimes.

pub const model_catalog = @import("model_catalog.zig");
pub const invocation = @import("invocation.zig");
pub const gateway = @import("gateway.zig");

pub const ModelCatalogEntry = model_catalog.ModelCatalogEntry;
pub const ModelCapabilities = model_catalog.ModelCapabilities;
pub const ModelSelection = model_catalog.ModelSelection;
pub const InvocationRole = invocation.InvocationRole;
pub const InvocationBudget = invocation.InvocationBudget;
pub const Gateway = gateway.Gateway;
pub const InferenceRequest = gateway.Request;
pub const InferenceResponse = gateway.Response;
pub const RegistryGateway = gateway.RegistryGateway;
pub const ToolDefinition = gateway.ToolDefinition;
