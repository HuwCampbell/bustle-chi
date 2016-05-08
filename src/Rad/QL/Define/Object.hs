{-# LANGUAGE ScopedTypeVariables #-} 

module Rad.QL.Define.Object
  ( defineObject
  , implements
  , ObjectDefM(..)
  ) where

import           Control.Arrow (first)
import           Data.Maybe (fromMaybe)
import           Data.Monoid ((<>))
import qualified Data.HashSet as HashSet
import qualified Data.Trie    as Trie

import Rad.QL.Internal.Builders
import Rad.QL.Internal.Types

import Rad.QL.Define.Field
import Rad.QL.Define.Util

import Rad.QL.AST
import Rad.QL.Query
import Rad.QL.Types

defineObject :: (Monad m) => Name -> ObjectDefM m a b -> GraphQLTypeDef OBJECT m a
defineObject n def = emptyDef
    { gqlTypeDef = TypeDefObject td
    , gqlResolve = res
    , gqlFields  = odFields def
    }
  where td  = ObjectTypeDef n (odDesc def) (odInterfaces def) fds
        fds = [ fieldDef f | f <- odFields def ]
        frs = Trie.fromList
                [ (fieldResolverName f, fieldResolver f)
                | f <- odFields def
                ]
        res = objectResolver td
            -- insert special __typename resolver
            $ Trie.insert "__typename" (resolveTypeName n) frs

objectResolver :: (Monad m)
               => ObjectTypeDef                   -- given an object definition (for type checking)
               -> Trie.Trie (FieldRunner m a)     -- and a trie of resolvers
               -> QSelectionSet -> a -> Result m  -- return a value resolver
objectResolver odef fdefs ss x = joinObject <$> traverse fval fields
  where fval (QField a n args ss') =
          alias a n <$> maybe (fieldNotDefined n)
                              (\r -> r args x ss')
                              (Trie.lookup n fdefs)
        fields = fst $ collapse HashSet.empty ss
        collapse visited [] = ([], visited)
        collapse visited (QSelectionField  f        : sels)
            | HashSet.member key visited = collapse                     visited  sels
            | otherwise    = first (f :) $ collapse (HashSet.insert key visited) sels
          where key = fieldKey f
        collapse visited (QSelectionSpread cond ss' : sels)
            | cond odef = let (fs, v') = collapse visited ss' in first (fs <>) $ collapse v' sels
            | otherwise = collapse visited sels

fieldResolverName :: GraphQLFieldDef m a -> Name
fieldResolverName = fieldDefName . fieldDef

fieldDefName :: FieldDef -> Name
fieldDefName (FieldDef n _ _ _ _ _) = n

fieldNotDefined :: (Monad m) => Name -> Result m
fieldNotDefined n = errorMsg $ "Field \"" <> n <> "\" is not defined"

fieldKey :: QField -> Name
fieldKey (QField "" n _ _) = n
fieldKey (QField a  _ _ _) = a

alias :: Alias -> Name -> Builder -> Builder
alias a n b = buildString k <> charUtf8 ':' <> b
  where k | a == ""   = n
          | otherwise = a

implements :: forall m a b. (GraphQLType INTERFACE m b) => (a -> b) -> ObjectDefM m a ()
implements fn = case gqlTypeDef idef of
    TypeDefInterface i -> unit
      { odInterfaces = [ i ]
      , odFields     = [ castField fn f | f <- gqlFields idef ]
      }
    _ -> unit
  where idef = def :: GraphQLTypeDef INTERFACE m b

-- object definition monad, used to trick the do notation into doing what we want
-- rebindable syntax seemed like overkill

data ObjectDefM m a b = ObjectDefM
  { odDesc       :: Description
  , odFields     :: [GraphQLFieldDef m a]
  , odInterfaces :: Interfaces
  }

instance DefinitionBuilder (ObjectDefM m a) where
  unit = ObjectDefM
    { odDesc       = ""
    , odFields     = []
    , odInterfaces = []
    }
  merge x y = ObjectDefM
    { odDesc       = odDesc       x <> odDesc       y
    , odFields     = odFields     y <> odFields     x -- reversed for shadowing
    , odInterfaces = odInterfaces x <> odInterfaces y
    }

instance Functor     (ObjectDefM m a) where fmap  = fmapDef
instance Applicative (ObjectDefM m a) where (<*>) = applyDef ; pure _ = unit
instance Monad       (ObjectDefM m a) where (>>=) = bindDef  ; (>>)   = seqDef

instance Describable (ObjectDefM m a) where
  describe d = unit { odDesc = d }

instance HasFields ObjectDefM m a b where
  fieldSingleton f = unit { odFields = [f] }
