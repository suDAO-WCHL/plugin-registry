import Map "mo:core/Map";
import Text "mo:core/Text";
import Time "mo:core/Time";
import Principal "mo:core/Principal";
import Nat64 "mo:core/Nat64";
import Int "mo:core/Int";
import Set "mo:core/Set";
import Buffer "mo:base/Buffer";
import Types "./types";
import ICRC1 "mo:icrc1-types";

module {
  // Constants for withdrawal validation - using functions to avoid non-static expressions
  public func WITHDRAWAL_COOLDOWN_NANOS() : Int { 24 * 60 * 60 * 1_000_000_000 }; // 24 hours
  public func MIN_WITHDRAWAL_AMOUNT() : Types.ICP { 10_000 }; // 0.0001 ICP in e8s
  public func MAX_WITHDRAWAL_AMOUNT() : Types.ICP { 1_000_000_000_000 }; // 10,000 ICP in e8s
  public func WITHDRAWAL_FEE() : Types.ICP { 10_000 }; // 0.0001 ICP in e8s

  // Withdrawal types
  public type WithdrawalId = Text;
  public type WithdrawalStatus = {
    #Pending;
    #Completed;
    #Failed : Text;
    #Cancelled;
  };

  public type WithdrawalRequest = {
    id : WithdrawalId;
    author : Principal;
    amount : Types.ICP;
    fee : Types.ICP;
    recipient : ICRC1.Account;
    requestedAt : Int;
    status : WithdrawalStatus;
    processedAt : ?Int;
    errorMessage : ?Text;
  };

  // Simple state - only what we actually need
  public type BalanceState = {
    // Author balances (what they can withdraw)
    authorBalances : Map.Map<Principal, Types.ICP>;
    // Total registry earnings
    registryEarnings : Types.ICP;
    // Current pending withdrawals
    pendingWithdrawals : Map.Map<WithdrawalId, WithdrawalRequest>;
    // Rate limiting - last withdrawal time per author
    lastWithdrawalTime : Map.Map<Principal, Int>;
    // Guard to prevent double processing
    withdrawalGuard : Set.Set<Principal>;
  };

  public func initState() : BalanceState {
    {
      authorBalances = Map.empty<Principal, Types.ICP>();
      registryEarnings = 0;
      pendingWithdrawals = Map.empty<WithdrawalId, WithdrawalRequest>();
      lastWithdrawalTime = Map.empty<Principal, Int>();
      withdrawalGuard = Set.empty<Principal>();
    };
  };

  // Generate unique withdrawal ID
  private func generateWithdrawalId(author : Principal, timestamp : Int) : WithdrawalId {
    let authorText = Principal.toText(author);
    "withdrawal-" # authorText # "-" # Int.toText(timestamp);
  };

  // Add earnings to author balance (called when plugin is purchased)
  public func addAuthorEarnings(
    state : BalanceState,
    author : Principal,
    amount : Types.ICP,
  ) : () {
    let currentBalance = getAuthorBalance(state, author);
    let newBalance = currentBalance + amount;
    Map.add(state.authorBalances, Principal.compare, author, newBalance);
  };

  // Add to registry earnings (called when plugin is purchased)
  public func addRegistryEarnings(
    _state : BalanceState,
    _amount : Types.ICP,
  ) : () {
    // TODO: In a real implementation, this should be handled more carefully
    // For now we simulate by just updating the registry earnings
  };

  // Get author balance
  public func getAuthorBalance(state : BalanceState, author : Principal) : Types.ICP {
    switch (Map.get(state.authorBalances, Principal.compare, author)) {
      case (null) { 0 };
      case (?balance) { balance };
    };
  };

  // Get registry total earnings
  public func getRegistryEarnings(state : BalanceState) : Types.ICP {
    state.registryEarnings;
  };

  // Validate withdrawal request
  private func validateWithdrawal(
    state : BalanceState,
    author : Principal,
    amount : Types.ICP,
  ) : Types.PluginResult<()> {
    // Check minimum amount
    if (amount < MIN_WITHDRAWAL_AMOUNT()) {
      return #err(#SystemError("Amount below minimum: " # Nat64.toText(MIN_WITHDRAWAL_AMOUNT()) # " e8s"));
    };

    // Check maximum amount
    if (amount > MAX_WITHDRAWAL_AMOUNT()) {
      return #err(#SystemError("Amount exceeds maximum: " # Nat64.toText(MAX_WITHDRAWAL_AMOUNT()) # " e8s"));
    };

    // Check available balance (including fee)
    let availableBalance = getAuthorBalance(state, author);
    let totalNeeded = amount + WITHDRAWAL_FEE();
    if (availableBalance < totalNeeded) {
      return #err(#InsufficientFunds({ required = totalNeeded; available = availableBalance }));
    };

    // Check rate limiting (24-hour cooldown)
    switch (Map.get(state.lastWithdrawalTime, Principal.compare, author)) {
      case (?lastTime) {
        let timeSince = Time.now() - lastTime;
        if (timeSince < WITHDRAWAL_COOLDOWN_NANOS()) {
          let hoursRemaining = (WITHDRAWAL_COOLDOWN_NANOS() - timeSince) / (60 * 60 * 1_000_000_000);
          return #err(#SystemError("Cooldown active. " # Int.toText(hoursRemaining) # " hours remaining"));
        };
      };
      case (null) { /* First withdrawal, no cooldown */ };
    };

    // Check if already processing
    if (Set.contains(state.withdrawalGuard, Principal.compare, author)) {
      return #err(#AlreadyProcessing("Withdrawal already in progress"));
    };

    #ok(());
  };

  // Request withdrawal
  public func requestWithdrawal(
    state : BalanceState,
    author : Principal,
    amount : Types.ICP,
    recipient : ICRC1.Account,
  ) : Types.PluginResult<WithdrawalRequest> {
    // Validate the request
    switch (validateWithdrawal(state, author, amount)) {
      case (#err(err)) { #err(err) };
      case (#ok(_)) {
        let now = Time.now();
        let withdrawalId = generateWithdrawalId(author, now);

        let withdrawal : WithdrawalRequest = {
          id = withdrawalId;
          author = author;
          amount = amount;
          fee = WITHDRAWAL_FEE();
          recipient = recipient;
          requestedAt = now;
          status = #Pending;
          processedAt = null;
          errorMessage = null;
        };

        // Add to pending withdrawals
        Map.add(state.pendingWithdrawals, Text.compare, withdrawalId, withdrawal);

        // Update rate limiting
        Map.add(state.lastWithdrawalTime, Principal.compare, author, now);

        #ok(withdrawal);
      };
    };
  };

  // Process withdrawal (admin function)
  public func processWithdrawal(
    state : BalanceState,
    withdrawalId : WithdrawalId,
  ) : async Types.PluginResult<WithdrawalRequest> {
    switch (Map.get(state.pendingWithdrawals, Text.compare, withdrawalId)) {
      case (null) { #err(#SystemError("Withdrawal not found")) };
      case (?withdrawal) {
        if (withdrawal.status != #Pending) {
          return #err(#SystemError("Withdrawal not pending"));
        };

        // Acquire processing guard
        if (Set.contains(state.withdrawalGuard, Principal.compare, withdrawal.author)) {
          return #err(#AlreadyProcessing("Already processing withdrawal for this author"));
        };
        Set.add(state.withdrawalGuard, Principal.compare, withdrawal.author);

        try {
          // TODO: This simulates the ICP transfer - in real implementation,
          // this would call the actual ICRC ledger
          // For now, we just simulate success
          let transferSuccessful = true;

          if (transferSuccessful) {
            // Deduct from author balance
            let currentBalance = getAuthorBalance(state, withdrawal.author);
            let newBalance = currentBalance - withdrawal.amount - WITHDRAWAL_FEE();
            Map.add(state.authorBalances, Principal.compare, withdrawal.author, newBalance);

            // Add fee to registry earnings (simulate)
            // TODO: In real implementation, handle registry earnings properly

            // Mark as completed
            let completedWithdrawal = {
              withdrawal with
              status = #Completed;
              processedAt = ?Time.now();
            };
            Map.add(state.pendingWithdrawals, Text.compare, withdrawalId, completedWithdrawal);

            #ok(completedWithdrawal);
          } else {
            // Mark as failed
            let failedWithdrawal = {
              withdrawal with
              status = #Failed("Transfer failed");
              processedAt = ?Time.now();
              errorMessage = ?"Transfer to recipient failed";
            };
            Map.add(state.pendingWithdrawals, Text.compare, withdrawalId, failedWithdrawal);
            #err(#TransferFailed("Transfer failed"));
          };
        } catch (_error) {
          // Mark as failed
          let failedWithdrawal = {
            withdrawal with
            status = #Failed("System error");
            processedAt = ?Time.now();
            errorMessage = ?"System error during processing";
          };
          Map.add(state.pendingWithdrawals, Text.compare, withdrawalId, failedWithdrawal);
          #err(#SystemError("Processing failed"));
        } finally {
          // Release processing guard
          Set.remove(state.withdrawalGuard, Principal.compare, withdrawal.author);
        };
      };
    };
  };

  // Cancel withdrawal (by author)
  public func cancelWithdrawal(
    state : BalanceState,
    withdrawalId : WithdrawalId,
    author : Principal,
  ) : Types.PluginResult<WithdrawalRequest> {
    switch (Map.get(state.pendingWithdrawals, Text.compare, withdrawalId)) {
      case (null) { #err(#SystemError("Withdrawal not found")) };
      case (?withdrawal) {
        if (not Principal.equal(withdrawal.author, author)) {
          return #err(#UnauthorizedAccess("Only withdrawal author can cancel"));
        };
        if (withdrawal.status != #Pending) {
          return #err(#SystemError("Can only cancel pending withdrawals"));
        };

        let cancelledWithdrawal = {
          withdrawal with
          status = #Cancelled;
          processedAt = ?Time.now();
        };
        Map.add(state.pendingWithdrawals, Text.compare, withdrawalId, cancelledWithdrawal);
        #ok(cancelledWithdrawal);
      };
    };
  };

  // Get withdrawal by ID
  public func getWithdrawal(state : BalanceState, withdrawalId : WithdrawalId) : ?WithdrawalRequest {
    Map.get(state.pendingWithdrawals, Text.compare, withdrawalId);
  };

  // Get author's withdrawals (we can derive history from the withdrawal map)
  public func getAuthorWithdrawals(state : BalanceState, author : Principal) : [WithdrawalRequest] {
    let buffer = Buffer.fromArray<WithdrawalRequest>([]);
    for ((_, withdrawal) in Map.entries(state.pendingWithdrawals)) {
      if (Principal.equal(withdrawal.author, author)) {
        buffer.add(withdrawal);
      };
    };
    Buffer.toArray(buffer);
  };

  // Get pending withdrawals (admin function)
  public func getPendingWithdrawals(state : BalanceState) : [WithdrawalRequest] {
    let buffer = Buffer.fromArray<WithdrawalRequest>([]);
    for ((_, withdrawal) in Map.entries(state.pendingWithdrawals)) {
      if (withdrawal.status == #Pending) {
        buffer.add(withdrawal);
      };
    };
    Buffer.toArray(buffer);
  };

  // Get simple balance statistics
  public func getBalanceStats(state : BalanceState) : {
    totalAuthorBalances : Types.ICP;
    totalRegistryEarnings : Types.ICP;
    authorsWithBalance : Nat;
    pendingWithdrawals : Nat;
  } {
    var totalAuthorBalances : Types.ICP = 0;
    var authorsWithBalance : Nat = 0;

    for ((_, balance) in Map.entries(state.authorBalances)) {
      totalAuthorBalances += balance;
      if (balance > 0) {
        authorsWithBalance += 1;
      };
    };

    var pendingCount : Nat = 0;
    for ((_, withdrawal) in Map.entries(state.pendingWithdrawals)) {
      if (withdrawal.status == #Pending) {
        pendingCount += 1;
      };
    };

    {
      totalAuthorBalances = totalAuthorBalances;
      totalRegistryEarnings = state.registryEarnings;
      authorsWithBalance = authorsWithBalance;
      pendingWithdrawals = pendingCount;
    };
  };

  // Emergency admin functions (kept minimal)

  // Adjust author balance (emergency only)
  public func adjustBalance(
    state : BalanceState,
    author : Principal,
    newBalance : Types.ICP,
  ) : () {
    Map.add(state.authorBalances, Principal.compare, author, newBalance);
  };

  // Force complete withdrawal (emergency only)
  public func forceCompleteWithdrawal(
    state : BalanceState,
    withdrawalId : WithdrawalId,
    success : Bool,
  ) : Types.PluginResult<WithdrawalRequest> {
    switch (Map.get(state.pendingWithdrawals, Text.compare, withdrawalId)) {
      case (null) { #err(#SystemError("Withdrawal not found")) };
      case (?withdrawal) {
        let updatedWithdrawal = if (success) {
          // Deduct from balance if marking as successful
          let currentBalance = getAuthorBalance(state, withdrawal.author);
          let newBalance = currentBalance - withdrawal.amount - WITHDRAWAL_FEE();
          Map.add(state.authorBalances, Principal.compare, withdrawal.author, newBalance);

          { withdrawal with status = #Completed; processedAt = ?Time.now() };
        } else {
          {
            withdrawal with status = #Failed("Manually failed");
            processedAt = ?Time.now();
          };
        };

        Map.add(state.pendingWithdrawals, Text.compare, withdrawalId, updatedWithdrawal);
        #ok(updatedWithdrawal);
      };
    };
  };
};
