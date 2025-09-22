import Text "mo:core/Text";
import Char "mo:core/Char";
import List "mo:core/List";
import Types "types";
import ICRC2 "mo:icrc2-types";
import Iter "mo:core/Iter";
import Option "mo:core/Option";

module {
  public func getICPActor() : ICRC2.Service {
    actor ("ryjl3-tyaaa-aaaaa-aaaba-cai") : ICRC2.Service;
  };

  public func strip(t : Text) : Text {
    Text.trim(t, #predicate(func(c : Char) : Bool { Char.isWhitespace(c) }));
  };

  public func getPurchaseShare(amount : Types.ICP) : {
    authorShare : Types.ICP;
    registryShare : Types.ICP;
  } {
    let authorShare = (amount * 70) / 100;
    let registryShare : Nat = amount - authorShare; // should never be negative (amount - 0.7*amount)
    { authorShare = authorShare; registryShare = registryShare };
  };

  public func commit() : async () {
    ();
  };

  // Set at last or add if empty
  public func setLastOrAdd<T>(list : List.List<T>, item : T) {
    let size = List.size(list);
    if (size == 0) {
      List.add(list, item);
    } else {
      List.put(list, size - 1 : Nat, item);
    };
  };

  public func getLastSafe<T>(list : List.List<T>) : ?T {
    let size = List.size(list);
    if (size == 0) {
      null;
    } else {
      List.get(list, size - 1 : Nat);
    };
  };

  // Map an iter that can result in null and filter out null values
  public func mapSafe<T, U>(list : Iter.Iter<T>, f : T -> ?U) : [U] {
    Iter.toArray(
      Iter.map(
        Iter.filter(
          Iter.map(list, f),
          Option.isSome,
        ),
        func(item : ?U) : U { Option.unwrap(item) },
      )
    );
  };
};
