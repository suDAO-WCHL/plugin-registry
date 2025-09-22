import Map "mo:core/Map";
import Array "mo:core/Array";
import Text "mo:core/Text";
import Time "mo:core/Time";
import Principal "mo:core/Principal";
import Nat "mo:core/Nat";
import List "mo:core/List";
import Types "./types";
import Purchase "./Purchase";

module {
  public type InstallState = {
    // Canister installations (canister -> array of installations)
    canisterInstallations : Map.Map<Principal, List.List<Types.Installation>>;
    // Plugin installations (pluginId -> array of installations) for analytics
    pluginInstallations : Map.Map<Types.PluginId, List.List<Types.Installation>>;
  };

  public func initState() : InstallState {
    {
      canisterInstallations = Map.empty<Principal, List.List<Types.Installation>>();
      pluginInstallations = Map.empty<Types.PluginId, List.List<Types.Installation>>();
    };
  };

  public type RequestInstallPlugin = {
    canister : Principal;
    pluginId : Types.PluginId;
    pluginVersion : Types.Version;
    pluginPrice : Types.ICP;
  };

  // Install a plugin for a canister
  public func installPlugin(
    state : InstallState,
    request : RequestInstallPlugin,
  ) : Types.PluginResult<Types.Installation> {
    let now = Time.now();

    let isPluginPurchased = Purchase.isPluginPurchased(purchaseState, request.canister, request.pluginId);
    if (request.pluginPrice > 0 and not request.isPluginPurchased) {
      return #err(#PluginNotPurchased({ pluginId = request.pluginId; canister = request.canister }));
    };

    // Check if plugin is already installed and active
    switch (Map.get(state.canisterInstallations, Principal.compare, canister)) {
      case (?installations) {
        for (installation in installations.vals()) {
          if (Text.equal(installation.pluginId, pluginId) and installation.isActive) {
            // Plugin already installed and active, update to new version if different
            if (installation.pluginVersion != pluginVersion) {
              // Deactivate old version and create new installation
              let updatedInstallations = updateInstallationInArray(installations, pluginId, installation);

              // Create new installation
              let newInstallation : Types.Installation = {
                pluginId = pluginId;
                pluginVersion = pluginVersion;
                canister = canister;
                installedAt = now;
                isActive = true;
              };

              let finalInstallations = addToArray(updatedInstallations, newInstallation);
              Map.add(state.canisterInstallations, Principal.compare, canister, finalInstallations);

              // Add to plugin installations
              updatePluginInstallations(state, pluginId, newInstallation);

              // Add to history
              addToHistory(state, canister, newInstallation);

              return #Ok(newInstallation);
            } else {
              // Same version already installed
              return #Err(#SystemError("Plugin version " # Nat.toText(pluginVersion) # " is already installed and active"));
            };
          };
        };
      };
      case (null) {};
    };

    // Create new installation
    let installation : Types.Installation = {
      pluginId = pluginId;
      pluginVersion = pluginVersion;
      canister = canister;
      installedAt = now;
      isActive = true;
    };

    // Add to canister installations
    switch (Map.get(state.canisterInstallations, Principal.compare, canister)) {
      case (null) {
        Map.add(state.canisterInstallations, Principal.compare, canister, [installation]);
      };
      case (?existingInstallations) {
        Map.add(state.canisterInstallations, Principal.compare, canister, addToArray(existingInstallations, installation));
      };
    };

    // Add to plugin installations for analytics
    updatePluginInstallations(state, pluginId, installation);

    // Add to history
    addToHistory(state, canister, installation);

    #Ok(installation);
  };

  // Helper function to update plugin installations
  private func updatePluginInstallations(
    state : InstallState,
    pluginId : Types.PluginId,
    installation : Types.Installation,
  ) : () {
    switch (Map.get(state.pluginInstallations, Text.compare, pluginId)) {
      case (null) {
        Map.add(state.pluginInstallations, Text.compare, pluginId, [installation]);
      };
      case (?existingInstallations) {
        Map.add(state.pluginInstallations, Text.compare, pluginId, addToArray(existingInstallations, installation));
      };
    };
  };

  // Helper function to add to installation history
  private func addToHistory(
    state : InstallState,
    canister : Principal,
    installation : Types.Installation,
  ) : () {
    switch (Map.get(state.installationHistory, Principal.compare, canister)) {
      case (null) {
        Map.add(state.installationHistory, Principal.compare, canister, [installation]);
      };
      case (?existingHistory) {
        Map.add(state.installationHistory, Principal.compare, canister, addToArray(existingHistory, installation));
      };
    };
  };

  // Uninstall a plugin (deactivate it)
  public func uninstallPlugin(
    state : InstallState,
    canister : Principal,
    pluginId : Types.PluginId,
  ) : Types.PluginResult<()> {
    switch (Map.get(state.canisterInstallations, Principal.compare, canister)) {
      case (null) {
        #Err(#SystemError("No plugins installed for this canister"));
      };
      case (?installations) {
        var found = false;
        let newInstallations = Array.map<Types.Installation, Types.Installation>(
          installations,
          func(installation : Types.Installation) : Types.Installation {
            if (Text.equal(installation.pluginId, pluginId) and installation.isActive) {
              found := true;

              // Add deactivation to history
              let deactivationRecord = {
                installation with
                installedAt = Time.now();
                isActive = false;
              };
              addToHistory(state, canister, deactivationRecord);

              // Return deactivated installation
              { installation with isActive = false };
            } else {
              installation;
            };
          },
        );

        if (found) {
          Map.add(state.canisterInstallations, Principal.compare, canister, newInstallations);
          #Ok(());
        } else {
          #Err(#SystemError("Plugin not found or not active"));
        };
      };
    };
  };

  // List installed plugins for a canister
  public func listInstalledPlugins(
    state : InstallState,
    canister : Principal,
    activeOnly : Bool,
  ) : [Types.Installation] {
    switch (Map.get(state.canisterInstallations, Principal.compare, canister)) {
      case (null) { [] };
      case (?installations) {
        if (activeOnly) {
          Array.filter<Types.Installation>(installations, func(installation : Types.Installation) : Bool { installation.isActive });
        } else {
          installations;
        };
      };
    };
  };

  // Check if a plugin is installed and active for a canister
  public func isPluginInstalled(
    state : InstallState,
    canister : Principal,
    pluginId : Types.PluginId,
  ) : Bool {
    switch (Map.get(state.canisterInstallations, Principal.compare, canister)) {
      case (null) { false };
      case (?installations) {
        var found = false;
        for (installation in installations.vals()) {
          if (Text.equal(installation.pluginId, pluginId) and installation.isActive) {
            found := true;
          };
        };
        found;
      };
    };
  };

  // Get installation history for a canister
  public func getInstallationHistory(
    state : InstallState,
    canister : Principal,
  ) : [Types.Installation] {
    switch (Map.get(state.installationHistory, Principal.compare, canister)) {
      case (null) { [] };
      case (?history) { history };
    };
  };

  // List all installations of a specific plugin
  public func listPluginInstallations(
    state : InstallState,
    pluginId : Types.PluginId,
    activeOnly : Bool,
  ) : [Types.Installation] {
    switch (Map.get(state.pluginInstallations, Text.compare, pluginId)) {
      case (null) { [] };
      case (?installations) {
        if (activeOnly) {
          Array.filter<Types.Installation>(installations, func(installation : Types.Installation) : Bool { installation.isActive });
        } else {
          installations;
        };
      };
    };
  };

  // Get specific installation details
  public func getInstallation(
    state : InstallState,
    canister : Principal,
    pluginId : Types.PluginId,
  ) : ?Types.Installation {
    switch (Map.get(state.canisterInstallations, Principal.compare, canister)) {
      case (null) { null };
      case (?installations) {
        Array.find<Types.Installation>(
          installations,
          func(installation : Types.Installation) : Bool {
            Text.equal(installation.pluginId, pluginId) and installation.isActive
          },
        );
      };
    };
  };

  // Get installation statistics
  public func getInstallationStats(state : InstallState) : {
    totalInstallations : Nat;
    activeInstallations : Nat;
    totalCanisters : Nat;
    totalPluginsInstalled : Nat;
  } {
    var activeInstallations = 0;
    var totalInstallations = 0;

    for ((canister, installations) in Map.entries(state.canisterInstallations)) {
      for (installation in installations.vals()) {
        totalInstallations += 1;
        if (installation.isActive) {
          activeInstallations += 1;
        };
      };
    };

    {
      totalInstallations = totalInstallations;
      activeInstallations = activeInstallations;
      totalCanisters = Map.size(state.canisterInstallations);
      totalPluginsInstalled = Map.size(state.pluginInstallations);
    };
  };
};
