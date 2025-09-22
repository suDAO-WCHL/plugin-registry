import Text "mo:core/Text";
import Time "mo:core/Time";
import Principal "mo:core/Principal";

import Types "./types";
import Plugin "./Plugin";
import Purchase "./Purchase";
import Install "./Install";
import Balance "./Balance";

persistent actor PluginRegistry {
  // Stable state for upgrades
  private var pluginState = Plugin.initState();
  private var purchaseState = Purchase.initState();
  private var installState = Install.initState();
  private var balanceState = Balance.initState();

  // Admin principal (can be set during deployment)
  private var adminPrincipal : ?Principal = null;

  // Helper function to check if caller is admin
  private func isAdmin(caller : Principal) : Bool {
    switch (adminPrincipal) {
      case (null) { false };
      case (?admin) { Principal.equal(caller, admin) };
    };
  };

  // Admin function to set admin principal
  public shared (msg) func setAdmin(newAdmin : Principal) : async Types.PluginResult<()> {
    let caller = msg.caller;
    // Only allow setting admin if no admin exists or caller is current admin
    switch (adminPrincipal) {
      case (null) {
        adminPrincipal := ?newAdmin;
        #Ok(());
      };
      case (?currentAdmin) {
        if (Principal.equal(caller, currentAdmin)) {
          adminPrincipal := ?newAdmin;
          #Ok(());
        } else {
          #Err(#UnauthorizedAccess("Only current admin can change admin"));
        };
      };
    };
  };

  // ====================================================================
  // PLUGIN MODULE FUNCTIONS
  // ====================================================================

  // Publish a new plugin or update existing one
  public shared (msg) func publishPlugin(publishRequest : Types.PublishRequest) : async Types.PluginResult<Types.Plugin> {
    let caller = msg.caller;
    Plugin.publishPlugin(
      pluginState,
      caller,
      publishRequest,
    );
  };

  // List all plugins with optional filtering
  public query func listPlugins(filter : ?Types.PluginFilter) : async [Types.Plugin] {
    Plugin.listPlugins(pluginState, filter);
  };

  // Get a specific plugin
  public query func getPlugin(pluginId : Types.PluginId) : async ?Types.Plugin {
    Plugin.getPlugin(pluginState, pluginId);
  };

  // Get plugin history
  public query func getPluginHistory(pluginId : Types.PluginId) : async ?[Types.PluginHistory] {
    Plugin.getPluginHistory(pluginState, pluginId);
  };

  // Get plugins by author
  public query func getPluginsByAuthor(author : Principal) : async [Types.Plugin] {
    Plugin.getPluginsByAuthor(pluginState, author);
  };

  // Remove a plugin (only by author)
  public shared (msg) func removePlugin(pluginId : Types.PluginId) : async Types.PluginResult<()> {
    let caller = msg.caller;
    Plugin.removePlugin(pluginState, caller, pluginId);
  };

  // ====================================================================
  // PURCHASE MODULE FUNCTIONS
  // ====================================================================

  // Buy a plugin for a canister
  public shared (msg) func buyPlugin(
    pluginId : Types.PluginId,
    canisterToBuy : Principal,
    paymentAmount : Types.ICP,
  ) : async Types.PluginResult<Types.Purchase> {
    let caller = msg.caller;

    // Get plugin details
    switch (Plugin.getPlugin(pluginState, pluginId)) {
      case (null) {
        #Err(#PluginNotFound(pluginId));
      };
      case (?plugin) {
        // Check if plugin is already purchased
        if (Purchase.isPluginPurchased(purchaseState, canisterToBuy, pluginId)) {
          return #Err(#SystemError("Plugin already purchased for this canister"));
        };

        await Purchase.buyPlugin(
          purchaseState,
          balanceState,
          pluginId,
          plugin.version,
          plugin.price,
          plugin.author,
          canisterToBuy,
          paymentAmount,
        );
      };
    };
  };

  // Check if a plugin is purchased by a canister
  public query func isPluginPurchased(canister : Principal, pluginId : Types.PluginId) : async Bool {
    Purchase.isPluginPurchased(purchaseState, canister, pluginId);
  };

  // List purchases by a canister
  public query func listPurchasesByCanister(canister : Principal) : async [Types.Purchase] {
    Purchase.listPurchasesByCanister(purchaseState, canister);
  };

  // List purchases of a specific plugin
  public query func listPurchasesByPlugin(pluginId : Types.PluginId) : async [Types.Purchase] {
    Purchase.listPurchasesByPlugin(purchaseState, pluginId);
  };

  // Get author earnings
  public query func getAuthorEarnings(author : Principal) : async Types.ICP {
    Purchase.getAuthorEarnings(balanceState, author);
  };

  // Get purchase by ID
  public query func getPurchase(purchaseId : Types.PurchaseId) : async ?Types.Purchase {
    Purchase.getPurchase(purchaseState, purchaseId);
  };

  // Admin function: Get registry earnings
  public shared (msg) func getRegistryEarnings() : async Types.PluginResult<Types.ICP> {
    let caller = msg.caller;
    if (not isAdmin(caller)) {
      return #Err(#UnauthorizedAccess("Only admin can view registry earnings"));
    };
    #Ok(Purchase.getRegistryEarnings(balanceState));
  };

  // Admin function: Retry failed purchase
  public shared (msg) func retryPurchase(purchaseId : Types.PurchaseId) : async Types.PluginResult<Types.Purchase> {
    let caller = msg.caller;
    if (not isAdmin(caller)) {
      return #Err(#UnauthorizedAccess("Only admin can retry purchases"));
    };
    await Purchase.retryPurchase(purchaseState, balanceState, purchaseId);
  };

  // ====================================================================
  // INSTALL MODULE FUNCTIONS
  // ====================================================================

  // Install a plugin for a canister
  public shared (msg) func installPlugin(
    canister : Principal,
    pluginId : Types.PluginId,
  ) : async Types.PluginResult<Types.Installation> {
    let caller = msg.caller;

    // Get plugin details
    switch (Plugin.getPlugin(pluginState, pluginId)) {
      case (null) {
        #Err(#PluginNotFound(pluginId));
      };
      case (?plugin) {
        // Check if plugin is purchased (if not free)
        let isPurchased = Purchase.isPluginPurchased(purchaseState, canister, pluginId);

        Install.installPlugin(
          installState,
          canister,
          pluginId,
          plugin.version,
          plugin.price,
          isPurchased,
        );
      };
    };
  };

  // Uninstall a plugin from a canister
  public shared (msg) func uninstallPlugin(
    canister : Principal,
    pluginId : Types.PluginId,
  ) : async Types.PluginResult<()> {
    let caller = msg.caller;
    Install.uninstallPlugin(installState, canister, pluginId);
  };

  // List installed plugins for a canister
  public query func listInstalledPlugins(canister : Principal, activeOnly : Bool) : async [Types.Installation] {
    Install.listInstalledPlugins(installState, canister, activeOnly);
  };

  // Check if a plugin is installed for a canister
  public query func isPluginInstalled(canister : Principal, pluginId : Types.PluginId) : async Bool {
    Install.isPluginInstalled(installState, canister, pluginId);
  };

  // Get installation history for a canister
  public query func getInstallationHistory(canister : Principal) : async [Types.Installation] {
    Install.getInstallationHistory(installState, canister);
  };

  // List all installations of a specific plugin
  public query func listPluginInstallations(pluginId : Types.PluginId, activeOnly : Bool) : async [Types.Installation] {
    Install.listPluginInstallations(installState, pluginId, activeOnly);
  };

  // Get specific installation details
  public query func getInstallation(canister : Principal, pluginId : Types.PluginId) : async ?Types.Installation {
    Install.getInstallation(installState, canister, pluginId);
  };

  // Bulk uninstall all plugins for a canister
  public shared (msg) func uninstallAllPlugins(canister : Principal) : async Types.PluginResult<Nat> {
    let caller = msg.caller;
    Install.uninstallAllPlugins(installState, canister);
  };

  // ====================================================================
  // BALANCE MODULE FUNCTIONS
  // ====================================================================

  // Get author balance
  public query func getAuthorBalance(author : Principal) : async Types.ICP {
    Balance.getAuthorBalance(balanceState, author);
  };

  // Request withdrawal
  public shared (msg) func requestWithdrawal(
    amount : Types.ICP,
    recipient : ICRC1.Account,
  ) : async Types.PluginResult<Balance.WithdrawalRequest> {
    let caller = msg.caller;
    Balance.requestWithdrawal(balanceState, caller, amount, recipient);
  };

  // Process withdrawal (admin only)
  public shared (msg) func processWithdrawal(
    withdrawalId : Balance.WithdrawalId
  ) : async Types.PluginResult<Balance.WithdrawalRequest> {
    let caller = msg.caller;
    if (not isAdmin(caller)) {
      return #Err(#UnauthorizedAccess("Only admin can process withdrawals"));
    };
    await Balance.processWithdrawal(balanceState, withdrawalId);
  };

  // Cancel withdrawal (by author)
  public shared (msg) func cancelWithdrawal(
    withdrawalId : Balance.WithdrawalId
  ) : async Types.PluginResult<Balance.WithdrawalRequest> {
    let caller = msg.caller;
    Balance.cancelWithdrawal(balanceState, withdrawalId, caller);
  };

  // Get withdrawal by ID
  public query func getWithdrawal(withdrawalId : Balance.WithdrawalId) : async ?Balance.WithdrawalRequest {
    Balance.getWithdrawal(balanceState, withdrawalId);
  };

  // Get author's withdrawals
  public query func getAuthorWithdrawals(author : Principal) : async [Balance.WithdrawalRequest] {
    Balance.getAuthorWithdrawals(balanceState, author);
  };

  // Get pending withdrawals (admin only)
  public shared (msg) func getPendingWithdrawals() : async Types.PluginResult<[Balance.WithdrawalRequest]> {
    let caller = msg.caller;
    if (not isAdmin(caller)) {
      return #Err(#UnauthorizedAccess("Only admin can view pending withdrawals"));
    };
    #Ok(Balance.getPendingWithdrawals(balanceState));
  };

  // Get balance statistics (admin only)
  public shared (msg) func getBalanceStats() : async Types.PluginResult<{ totalAuthorBalances : Types.ICP; totalRegistryEarnings : Types.ICP; authorsWithBalance : Nat; pendingWithdrawals : Nat }> {
    let caller = msg.caller;
    if (not isAdmin(caller)) {
      return #Err(#UnauthorizedAccess("Only admin can view balance statistics"));
    };
    #Ok(Balance.getBalanceStats(balanceState));
  };

  // Emergency balance adjustment (admin only)
  public shared (msg) func adjustBalance(
    author : Principal,
    newBalance : Types.ICP,
  ) : async Types.PluginResult<()> {
    let caller = msg.caller;
    if (not isAdmin(caller)) {
      return #Err(#UnauthorizedAccess("Only admin can adjust balances"));
    };
    Balance.adjustBalance(balanceState, author, newBalance);
    #Ok(());
  };

  // Force complete withdrawal (emergency, admin only)
  public shared (msg) func forceCompleteWithdrawal(
    withdrawalId : Balance.WithdrawalId,
    success : Bool,
  ) : async Types.PluginResult<Balance.WithdrawalRequest> {
    let caller = msg.caller;
    if (not isAdmin(caller)) {
      return #Err(#UnauthorizedAccess("Only admin can force complete withdrawals"));
    };
    Balance.forceCompleteWithdrawal(balanceState, withdrawalId, success);
  };

  // ====================================================================
  // STATISTICS AND ANALYTICS
  // ====================================================================

  // Get comprehensive registry statistics
  public query func getRegistryStats() : async Types.RegistryStats {
    let pluginStats = Plugin.getStats(pluginState);
    let purchaseStats = Purchase.getPurchaseStats(purchaseState, balanceState);
    let installStats = Install.getInstallationStats(installState);

    {
      totalPlugins = pluginStats.totalPlugins;
      totalPurchases = purchaseStats.totalPurchases;
      totalInstallations = installStats.totalInstallations;
      totalRevenue = purchaseStats.totalRevenue;
    };
  };

  // Get detailed statistics (admin only)
  public shared (msg) func getDetailedStats() : async Types.PluginResult<{ pluginStats : { totalPlugins : Nat; totalAuthors : Nat }; purchaseStats : { totalPurchases : Nat; totalRevenue : Types.ICP; totalAuthorEarnings : Types.ICP; totalRegistryEarnings : Types.ICP }; installStats : { totalInstallations : Nat; activeInstallations : Nat; totalCanisters : Nat; totalPluginsInstalled : Nat } }> {
    let caller = msg.caller;
    if (not isAdmin(caller)) {
      return #Err(#UnauthorizedAccess("Only admin can view detailed statistics"));
    };

    #Ok({
      pluginStats = Plugin.getStats(pluginState);
      purchaseStats = Purchase.getPurchaseStats(purchaseState, balanceState);
      installStats = Install.getInstallationStats(installState);
    });
  };

  // ====================================================================
  // UTILITY FUNCTIONS
  // ====================================================================

  // Get current time
  public query func getCurrentTime() : async Int {
    Time.now();
  };

  // Health check
  public query func healthCheck() : async { status : Text; timestamp : Int } {
    {
      status = "healthy";
      timestamp = Time.now();
    };
  };

  // Get canister version/info
  public query func getCanisterInfo() : async {
    name : Text;
    version : Text;
    totalPlugins : Nat;
    totalPurchases : Nat;
    totalInstallations : Nat;
  } {
    let pluginStats = Plugin.getStats(pluginState);
    let purchaseStats = Purchase.getPurchaseStats(purchaseState);
    let installStats = Install.getInstallationStats(installState);

    {
      name = "Plugin Registry";
      version = "1.0.0";
      totalPlugins = pluginStats.totalPlugins;
      totalPurchases = purchaseStats.totalPurchases;
      totalInstallations = installStats.totalInstallations;
    };
  };
};
