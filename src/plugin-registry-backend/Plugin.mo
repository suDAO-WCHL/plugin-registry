import Map "mo:core/Map";
import Text "mo:core/Text";
import Time "mo:core/Time";
import Principal "mo:core/Principal";
import Nat "mo:core/Nat";
import List "mo:core/List";
import Types "./types";
import Utils "./Utils";

module {
  public type PluginState = {
    // Current plugins (pluginId -> latest plugin)
    plugins : Map.Map<Types.PluginId, Types.Plugin>;
    // Plugin history (pluginId -> array of versions)
    pluginHistory : Map.Map<Types.PluginId, List.List<Types.PluginHistory>>;
  };

  public func initState() : PluginState {
    {
      plugins = Map.empty<Types.PluginId, Types.Plugin>();
      pluginHistory = Map.empty<Types.PluginId, List.List<Types.PluginHistory>>();
    };
  };

  // Validate plugin data
  private func validatePlugin(plugin : Types.Plugin) : Types.PluginResult<()> {
    if (Principal.isAnonymous(plugin.author)) {
      return #err(#UnauthorizedAccess("You must be logged in to publish a plugin"));
    };
    if (Text.size(plugin.id) == 0) {
      return #err(#InvalidPluginData("Plugin ID cannot be empty"));
    } else {
      for (char in plugin.id.chars()) {
        if ((char < 'a' or char > 'z') and (char < 'A' or char > 'Z') and (char < '0' or char > '9')) {
          return #err(#InvalidPluginData("Plugin ID must be ascii alphanumeric within the regex ^[a-zA-Z0-9]+$"));
        };
      };
    };
    if (plugin.title.size() == 0) {
      return #err(#InvalidPluginData("Plugin title cannot be empty"));
    };
    if (plugin.description.size() == 0) {
      return #err(#InvalidPluginData("Plugin description cannot be empty"));
    };
    if (plugin.version <= 0) {
      return #err(#InvalidPluginData("Plugin version must be greater than 0"));
    };
    if (plugin.price < 0) {
      return #err(#InvalidPluginData("Plugin price cannot be negative"));
    };
    if (plugin.sourceFiles.size() == 0) {
      return #err(#InvalidPluginData("Plugin must have at least one source file"));
    };
    #ok;
  };

  // Publish or update a plugin
  public func publishPlugin(
    state : PluginState,
    caller : Principal,
    request : Types.PublishRequest,
  ) : Types.PluginResult<Types.PluginResponse> {
    let now = Time.now();
    let pluginId = Utils.strip(request.id);

    var newPlugin : Types.Plugin = {
      id = pluginId;
      title = Utils.strip(request.title);
      description = Utils.strip(request.description);
      version = request.version;
      author = caller;
      icon = request.icon;
      price = request.priceE8s;
      tags = request.tags;
      dependencies = request.dependencies;
      sourceFiles = request.sourceFiles;
      createdAt = now;
      updatedAt = now;
    };

    // Validate plugin data
    switch (validatePlugin(newPlugin)) {
      case (#err(error)) { return #err(error) };
      case (#ok(_)) {};
    };

    // Check if plugin exists
    switch (Map.get(state.plugins, Text.compare, pluginId)) {
      case (?existingPlugin) {
        // Plugin exists - check ownership and version
        if (existingPlugin.author != caller) {
          return #err(#UnauthorizedAccess("Only the plugin author can update this plugin"));
        };

        if (request.version <= existingPlugin.version) {
          return #err(#InvalidVersion({ current = existingPlugin.version; provided = request.version }));
        };

        // Update plugin
        newPlugin := {
          newPlugin with
          createdAt = existingPlugin.createdAt;
        };
      };
      case null {};
    };
    // Store plugin
    Map.add(state.plugins, Text.compare, pluginId, newPlugin);

    // Add to history
    let historyEntry : Types.PluginHistory = {
      version = request.version;
      plugin = newPlugin;
      publishedAt = now;
    };
    switch (Map.get(state.pluginHistory, Text.compare, pluginId)) {
      case (?existingHistory) {
        List.add(existingHistory, historyEntry);
      };
      case (null) {
        Map.add(state.pluginHistory, Text.compare, pluginId, List.singleton<Types.PluginHistory>(historyEntry));
      };
    };

    #ok((pluginId, newPlugin));
  };

  // List all plugins with optional filtering
  public func listPlugins(
    state : PluginState,
    filter : ?Types.PluginFilter,
  ) : List.List<Types.PluginResponse> {
    var allPlugins = List.empty<Types.PluginResponse>();
    label filterLoop for ((pluginId, plugin) in Map.entries(state.plugins)) {
      switch (filter) {
        case (null) {};
        case (?f) {
          if (f.freeOnly and plugin.price > 0) {
            continue filterLoop;
          };
          switch (f.author) {
            case (null) {};
            case (?requiredAuthor) {
              if (plugin.author != requiredAuthor) {
                continue filterLoop;
              };
            };
          };

          switch (f.priceRange) {
            case (null) {};
            case (?range) {
              if (plugin.price < range.min or plugin.price > range.max) {
                continue filterLoop;
              };
            };
          };

          switch (f.tags, plugin.tags) {
            // only select if plugin.tags contains f.tags.
            case (?_, null) continue filterLoop; // we have filter but plugin has no tags, skip.
            case (?requiredTags, ?pluginTags) {
              for (requiredTag in requiredTags.vals()) {
                var found = false;
                label pluginTagLoop for (pluginTag in pluginTags.vals()) {
                  if (requiredTag == pluginTag) {
                    found := true;
                    break pluginTagLoop;
                  };
                };
                if (not found) {
                  continue filterLoop;
                };
              };
            };
            case _ {};
          };
        };
      };

      List.add(allPlugins, (pluginId, plugin));
    };
    allPlugins;
  };

  // Get a specific plugin
  public func getPlugin(
    state : PluginState,
    pluginId : Types.PluginId,
  ) : ?Types.Plugin {
    Map.get(state.plugins, Text.compare, pluginId);
  };

  // Get plugin history
  public func getPluginHistory(
    state : PluginState,
    pluginId : Types.PluginId,
  ) : ?List.List<Types.PluginHistory> {
    Map.get(state.pluginHistory, Text.compare, pluginId);
  };

  // Get plugins by author
  public func getPluginsByAuthor(
    state : PluginState,
    author : Principal,
  ) : List.List<Types.PluginResponse> {
    var plugins = List.empty<Types.PluginResponse>();
    for ((pluginId, plugin) in Map.entries(state.plugins)) {
      if (plugin.author == author) {
        List.add(plugins, (pluginId, plugin));
      };
    };
    plugins;
  };

  // Remove a plugin (only by author)
  public func removePlugin(
    state : PluginState,
    caller : Principal,
    pluginId : Types.PluginId,
  ) : Types.PluginResult<()> {
    switch (Map.get(state.plugins, Text.compare, pluginId)) {
      case (null) {
        #err(#PluginNotFound(pluginId));
      };
      case (?plugin) {
        if (plugin.author != caller) {
          return #err(#UnauthorizedAccess("Only the plugin author can remove this plugin"));
        };

        // Remove from main plugins map
        Map.remove(state.plugins, Text.compare, pluginId);
        Map.remove(state.pluginHistory, Text.compare, pluginId);
        #ok;
      };
    };
  };

  // Get registry statistics
  public func getStats(state : PluginState) : {
    totalPlugins : Nat;
  } {
    {
      totalPlugins = Map.size(state.plugins);
    };
  };
};
