import Map "mo:core/Map";
import Text "mo:core/Text";
import Time "mo:core/Time";
import Principal "mo:core/Principal";
import Nat64 "mo:core/Nat64";
import Types "./types";
import Set "mo:core/Set";
import Utils "./Utils";
import List "mo:core/List";
import Option "mo:core/Option";
import Error "mo:core/Error";
import Debug "mo:core/Debug";
import ICRC2 "mo:icrc2-types";

module {
  public type PurchaseState = {
    // Purchase records (purchaseId -> purchase)
    purchases : Map.Map<Types.PurchaseId, Types.Purchase>;
    // Canister purchases (canister -> set of purchaseIds)
    canisterPurchases : Map.Map<Principal, Set.Set<Types.PurchaseId>>;
    // Plugin purchases (pluginId -> set of purchaseIds)
    pluginPurchases : Map.Map<Types.PluginId, Set.Set<Types.PurchaseId>>;
  };

  public func initState() : PurchaseState {
    {
      purchases = Map.empty<Types.PurchaseId, Types.Purchase>();
      canisterPurchases = Map.empty<Principal, Set.Set<Types.PurchaseId>>();
      pluginPurchases = Map.empty<Types.PluginId, Set.Set<Types.PurchaseId>>();
    };
  };

  // Generate unique purchase ID
  private func generatePurchaseId(pluginId : Types.PluginId, buyer : Principal) : Types.PurchaseId {
    pluginId # ";" # Principal.toText(buyer);
  };

  // Record a completed purchase
  private func recordCompletedPurchase(
    state : PurchaseState,
    purchaseId : Types.PurchaseId,
    newPurchase : Types.Purchase,
  ) {
    let purchase = newPurchase;

    // Add to canister purchases
    switch (Map.get(state.canisterPurchases, Principal.compare, purchase.to)) {
      case (null) {
        Map.add(state.canisterPurchases, Principal.compare, purchase.to, Set.singleton(purchaseId));
      };
      case (?existingSet) {
        Set.add(existingSet, Types.comparePurchaseId, purchaseId);
      };
    };

    // Add to plugin purchases for analytics
    let pluginId = purchase.pluginId;
    switch (Map.get(state.pluginPurchases, Text.compare, pluginId)) {
      case (null) {
        Map.add(state.pluginPurchases, Text.compare, pluginId, Set.singleton(purchaseId));
      };
      case (?existingSet) {
        Set.add(existingSet, Types.comparePurchaseId, purchaseId);
      };
    };
  };

  public type BuyPluginArgs = {
    txBlock : Nat64;
    from : Principal;
    to : Principal;
    pluginId : Types.PluginId;
    pluginPrice : Types.ICP;
  };

  // Buy a plugin for a canister
  public func buyPlugin(
    state : PurchaseState,
    registryPrincipal : Principal,
    args : BuyPluginArgs,
  ) : async Types.PluginResult<Types.PurchaseId> {
    let now = Time.now();
    let pluginId = args.pluginId;
    let purchaseId = generatePurchaseId(pluginId, args.to);

    // Check if existing purchase history exists
    let newPurchaseHistory : Types.PurchaseHistory = {
      from = args.from;
      amount = args.pluginPrice;
      createdAt = Nat64.fromIntWrap(now);
      var transactionStatus = #Pending;
    };
    var newPurchase : ?Types.Purchase = null;
    switch (Map.get(state.purchases, Text.compare, purchaseId)) {
      case (null) {};
      case (?purchase) {
        let history = Option.unwrap(List.last(purchase.history)); // Should always not null
        switch (history.transactionStatus) {
          case (#Completed _) {
            return #err(#PluginAlreadyPurchased({ pluginId = pluginId; canister = args.to }));
          };
          case (#Pending) {
            return #err(#AlreadyProcessing("Purchase is already in progress"));
          };
          case _ {
            // #CallRejected or #Failed
            List.add(purchase.history, newPurchaseHistory);
            newPurchase := ?purchase;
          };
        };
      };
    };
    let purchase = Option.get(
      newPurchase,
      {
        id = purchaseId;
        pluginId = pluginId;
        to = args.to;
        history = List.singleton<Types.PurchaseHistory>(newPurchaseHistory);
      },
    );

    // Add to purchases with pending status first (journaling - commit)
    // Important: recordCompletedPurchase does not include this, so it should be before free.
    Map.add(state.purchases, Text.compare, purchaseId, purchase);

    // Check if plugin is free
    if (args.pluginPrice == 0) {
      newPurchaseHistory.transactionStatus := #Completed(null);
      recordCompletedPurchase(
        state,
        purchaseId,
        purchase,
      );
      return #ok(purchaseId);
    };

    // Do transfer
    let icp = Utils.getICPActor();
    var result : ?ICRC2.TransferFromResult = null;
    var ret : ?Types.PluginResult<Types.PurchaseId> = null;
    try {
      let res = await icp.icrc2_transfer_from({
        to = { owner = registryPrincipal; subaccount = null };
        fee = null;
        spender_subaccount = null;
        from = { owner = newPurchaseHistory.from; subaccount = null };
        memo = ?Text.encodeUtf8(purchaseId);
        created_at_time = ?newPurchaseHistory.createdAt;
        amount = args.pluginPrice;
      });
      result := ?res;
    } catch (error) {
      let errMsg = Error.message(error);
      newPurchaseHistory.transactionStatus := #CallRejected(errMsg);
      Debug.print("[buyPlugin] Transfer failed: '" # errMsg # "' with purchaseId: " # purchaseId);
      ret := ?#err(#AsyncCallFailed(errMsg));
    };

    switch (result) {
      case (?#Ok(block)) {
        newPurchaseHistory.transactionStatus := #Completed(?block);
        recordCompletedPurchase(state, purchaseId, purchase);
        #ok(purchaseId);
      };
      case (?#Err(error)) {
        newPurchaseHistory.transactionStatus := #Failed(error);
        #err(#TransferFailed(error));
      };
      case null Option.unwrap(ret);
    };
  };

  // Check if a plugin is purchased by a canister
  public func isPluginPurchased(
    state : PurchaseState,
    pluginId : Types.PluginId,
    canister : Principal,
  ) : Bool {
    let purchaseId = generatePurchaseId(pluginId, canister);
    switch (Map.get(state.purchases, Text.compare, purchaseId)) {
      case null false;
      case (?purchase) {
        switch (Utils.getLastSafe(purchase.history)) {
          case null false;
          case (?history) {
            switch (history.transactionStatus) {
              case (#Completed _) true;
              case _ false;
            };
          };
        };
      };
    };
  };

  // List all purchases by a canister
  public func listPurchasesByCanister(
    state : PurchaseState,
    canister : Principal,
  ) : [Types.Purchase] {
    switch (Map.get(state.canisterPurchases, Principal.compare, canister)) {
      case null [];
      case (?purchaseIds) {
        Utils.mapSafe(
          Set.values(purchaseIds),
          func(purchaseId : Types.PurchaseId) : ?Types.Purchase {
            Map.get(state.purchases, Text.compare, purchaseId);
          },
        );
      };
    };
  };

  // List all purchases of a specific plugin
  public func listPurchasesByPlugin(
    state : PurchaseState,
    pluginId : Types.PluginId,
  ) : [Types.Purchase] {
    switch (Map.get(state.pluginPurchases, Text.compare, pluginId)) {
      case null [];
      case (?purchaseIds) {
        Utils.mapSafe(
          Set.values(purchaseIds),
          func(purchaseId : Types.PurchaseId) : ?Types.Purchase {
            Map.get(state.purchases, Text.compare, purchaseId);
          },
        );
      };
    };
  };

  // Get purchase by ID
  public func getPurchase(
    state : PurchaseState,
    purchaseId : Types.PurchaseId,
  ) : ?Types.Purchase {
    Map.get(state.purchases, Text.compare, purchaseId);
  };

  type PurchaseStats = {
    totalFailedPurchases : Nat;
    totalPendingPurchases : Nat;
    totalCompletedPurchases : Nat;
  };

  // Get purchase statistics
  public func getPurchaseStats(
    state : PurchaseState
  ) : {
    purchaseStats : PurchaseStats;
  } {
    let acc = Map.foldLeft(
      state.purchases,
      {
        var totalFailedPurchases = 0;
        var totalPendingPurchases = 0;
        var totalCompletedPurchases = 0;
      },
      func(acc, _ : Types.PurchaseId, purchase : Types.Purchase) {
        switch (Utils.getLastSafe(purchase.history)) {
          case (?history) {
            switch (history.transactionStatus) {
              case (#Failed(_)) {
                acc.totalFailedPurchases += 1;
              };
              case (#Pending) {
                acc.totalPendingPurchases += 1;
              };
              case (#Completed(_)) {
                acc.totalCompletedPurchases += 1;
              };
              case _ {};
            };
          };
          case _ {};
        };
        acc;
      },
    );
    {
      purchaseStats = {
        totalFailedPurchases = acc.totalFailedPurchases;
        totalPendingPurchases = acc.totalPendingPurchases;
        totalCompletedPurchases = acc.totalCompletedPurchases;
      };
    };
  };
};
