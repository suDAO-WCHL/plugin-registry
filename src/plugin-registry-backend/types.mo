import Principal "mo:core/Principal";
import Result "mo:core/Result";
import Order "mo:core/Order";
import Text "mo:core/Text";
import List "mo:core/List";
import ICRC2 "mo:icrc2-types";

module {
  public type PluginId = Text;
  public type Version = Nat;
  public type ICP = Nat; // ICP amount in e8s (1 ICP = 100,000,000 e8s)

  public type FileType = {
    #FrontendUrl : {
      src : Text;
    };
    #FrontendBundle : {
      file : Blob;
    };
    #BackendPullable : {
      wasmUrl : Text;
      candidUrl : Text;
      canister : Principal;
    };
    #BackendCandid : {
      candidIdl : Text;
      canister : Principal;
    };
  };

  public type SourceFile = {
    id : Text;
    fileType : FileType;
  };

  // Request types
  public type PublishRequest = {
    id : Text;
    title : Text;
    description : Text;
    version : Version;
    icon : ?Blob;
    priceE8s : ICP;
    tags : ?[Text];
    dependencies : ?[PluginId];
    sourceFiles : [SourceFile];
  };

  // Plugin types
  public type Plugin = {
    id : PluginId;
    title : Text;
    description : Text;
    version : Version;
    author : Principal;
    icon : ?Blob;
    price : ICP; // Price in e8s, 0 for free
    tags : ?[Text];
    dependencies : ?[PluginId];
    sourceFiles : [SourceFile];
    createdAt : Int;
    updatedAt : Int;
  };
  public type PluginResponse = (PluginId, Plugin);

  public type PluginHistory = {
    version : Version;
    plugin : Plugin;
    publishedAt : Int;
  };

  // Purchase related types
  public type PurchaseId = Text;
  public func comparePurchaseId(a : PurchaseId, b : PurchaseId) : Order.Order {
    Text.compare(a, b);
  };

  public type Purchase = {
    id : PurchaseId;
    pluginId : PluginId;
    to : Principal;
    history : List.List<PurchaseHistory>;
  };

  public type PurchaseHistory = {
    from : Principal;
    amount : ICP;
    createdAt : Nat64;
    var transactionStatus : TransactionStatus;
  };

  public type TransactionStatus = {
    #Pending;
    #Completed : ?Nat; // block (or null if free)
    #CallRejected : Text;
    #Failed : ICRC2.TransferFromError;
  };

  // Install related types
  public type Installation = {
    pluginId : PluginId;
    pluginVersion : Version;
    canister : Principal;
    installedAt : Int;
    isActive : Bool;
  };

  // Error types
  public type RegistryError = {
    #PluginNotFound : PluginId;
    #PluginExists : PluginId;
    #UnauthorizedAccess : Text;
    #InvalidVersion : { current : Version; provided : Version };
    #InsufficientFunds : { required : ICP; available : ICP };
    #TransferFailed : ICRC2.TransferFromError;
    #AsyncCallFailed : Text;
    #PluginNotPurchased : { pluginId : PluginId; canister : Principal };
    #InvalidPluginData : Text;
    #SystemError : Text;
    #AlreadyProcessing : Text;
    #PluginAlreadyPurchased : { pluginId : PluginId; canister : Principal };
    #WithdrawalNotFound : Text;
    #WithdrawalInvalidStatus : Text;
    #WithdrawalCooldownActive : { remainingHours : Int };
    #MinimumWithdrawalAmount : { minimum : ICP; provided : ICP };
    #MaximumWithdrawalAmount : { maximum : ICP; provided : ICP };
  };

  public type PluginResult<T> = Result.Result<T, RegistryError>;

  // Statistics and metadata
  public type RegistryStats = {
    totalPlugins : Nat;
    totalPurchases : Nat;
    totalInstallations : Nat;
    totalRevenue : ICP;
  };

  // Search and filtering
  public type PluginFilter = {
    tags : ?[Text];
    author : ?Principal;
    priceRange : ?{ min : ICP; max : ICP };
    freeOnly : Bool;
  };
};
