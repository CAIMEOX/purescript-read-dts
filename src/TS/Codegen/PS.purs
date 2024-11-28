module TS.Codegen.PS where

import Prelude

import Control.Alt (alt, (<|>))
import Control.Apply (lift2)
import Control.Lazy (defer)
import Control.Monad.Error.Class (class MonadThrow, class MonadError, catchError, throwError)
import Control.Monad.Free (Free, runFree)
import Control.Monad.Reader (ReaderT(..), ask, mapReader, withReader)
import Control.Monad.Reader.Trans (mapReaderT, withReaderT)
import Control.Monad.State (StateT(..), State, gets, modify_, put, runStateT, state)
import Control.Monad.Trans.Class (class MonadTrans, lift)
import Control.Monad.Reader.Class (class MonadAsk, class MonadReader, ask, asks, local)
import Data.Foldable (for_)
import Data.Functor.Mu (Mu)
import Data.Identity (Identity(..))
import Data.List (List(..)) as List
import Data.Map (Map)
import Data.Map (empty, fromFoldable, insert, lookup) as Map
import Data.Maybe (Maybe(..))
import Data.Newtype (class Newtype)
import Data.Set (empty) as Set
import Data.Tuple.Nested ((/\))
import Partial.Unsafe (unsafePartial)
import PureScript.CST.Types as CST
import ReadDTS.AST (TsType, TypeRepr(..), RootDeclarations) as TS
import ReadDTS.AST (TypeRepr(..))
import Safe.Coerce (coerce) as Safe
import TS.Codegen.PS.ModulePath (ModulePath(..))
import TS.Codegen.PS.Types (Fqn(..))
import Tidy.Codegen (typeApp, typeCtor, typeVar) as TC
import Tidy.Codegen.Class (class ToName) as TC
import Tidy.Codegen.Monad (Codegen, CodegenState, CodegenT(..)) as TC
import Tidy.Codegen.Monad (CodegenState, Codegen)
import TypeScript.Compiler.Types (FullyQualifiedName(..))
import TypeScript.Compiler.Types (FullyQualifiedName(..)) as TS
import TypeScript.Compiler.Types (Program) as TSC

type Modules e = Map ModulePath (TC.CodegenState e)

type PackageCodegenState e =
  { modules :: Modules e
  , types :: Map TS.FullyQualifiedName Fqn
  }

-- | Let's start simple:
-- | * basic composition of codegen handlers
-- | * some ts -> ps mapping is probably not best and flexible approach...
newtype TypeReprCodegen e m = TypeReprCodegen (TS.FullyQualifiedName -> TS.TypeRepr -> PackageCodegenT e m (Maybe Fqn))

derive instance Newtype (TypeReprCodegen e m) _
instance Monad m => Semigroup (TypeReprCodegen e m) where
  append (TypeReprCodegen c1) (TypeReprCodegen c2) = TypeReprCodegen \tsFqn repr ->
    c1 tsFqn repr >>= case _ of
      Just psFqn -> pure $ Just psFqn
      Nothing -> c2 tsFqn repr

instance Monad m => Monoid (TypeReprCodegen e m) where
  mempty = TypeReprCodegen $ const $ const $ pure Nothing

newtype PackageCodegenT e m a = PackageCodegenT (ReaderT TS.RootDeclarations (StateT (PackageCodegenState e) m) a)

derive newtype instance Functor m => Functor (PackageCodegenT e m)
derive newtype instance Monad m => Apply (PackageCodegenT e m)
derive newtype instance Monad m => Applicative (PackageCodegenT e m)
derive newtype instance Monad m => Bind (PackageCodegenT e m)
derive newtype instance Monad m => Monad (PackageCodegenT e m)
derive newtype instance Monad m => MonadReader TS.RootDeclarations (PackageCodegenT e m)
derive newtype instance Monad m => MonadAsk TS.RootDeclarations (PackageCodegenT e m)
instance MonadTrans (PackageCodegenT e) where
  lift m = PackageCodegenT $ lift $ lift $ m

instance MonadThrow e m => MonadThrow e (PackageCodegenT s m) where
  throwError e = lift (throwError e)

instance MonadError e m => MonadError e (PackageCodegenT e m) where
  catchError (PackageCodegenT m) h = PackageCodegenT $
    catchError m (\e -> case h e of PackageCodegenT s -> s)

type PackageCodegen e = PackageCodegenT e (Free Identity)

emptyModuleCodegenState :: forall e. TC.CodegenState e
emptyModuleCodegenState =
  { exports: Set.empty
  , importsOpen: Set.empty
  , importsFrom: Map.empty
  , importsQualified: Map.empty
  , declarations: List.Nil
  }

withModule :: forall a e. ModulePath -> TC.Codegen e a -> PackageCodegen e a
withModule mp (TC.CodegenT c) = PackageCodegenT $ state \st@{ modules } -> do
  let
    cs = case Map.lookup mp modules of
      Just s -> s
      Nothing -> emptyModuleCodegenState
    a /\ cs' = runFree Safe.coerce <<< runStateT c $ cs
    modules' = Map.insert mp cs' modules
  a /\ st { modules = modules' }

eff :: forall e. CST.Type e -> CST.Type e
eff a = unsafePartial $ TC.typeApp (TC.typeCtor "Effect.Effect") [ a ]

eff' :: forall e n. TC.ToName n CST.Ident => n -> CST.Type e
eff' a = eff (TC.typeVar a)

lookupPSType :: forall e m. Monad m => TS.FullyQualifiedName -> PackageCodegenT e m (Maybe Fqn)
lookupPSType tsFqn = PackageCodegenT $ gets (_.types >>> Map.lookup tsFqn)

lookupTsDecl :: forall e m. Monad m => TS.FullyQualifiedName -> PackageCodegenT e m (Maybe TS.TypeRepr)
lookupTsDecl tsFqn = PackageCodegenT $ asks (Map.lookup tsFqn)

codegen :: forall e m. MonadError String m => Monad m => Array TS.FullyQualifiedName -> TypeReprCodegen e m -> PackageCodegenT e m Unit
codegen genNames (TypeReprCodegen typeReprCodegen) = do
  for_ genNames \fqn -> do
    asks (Map.lookup fqn) >>= case _ of
      Just t -> void $ typeReprCodegen fqn t
      Nothing -> throwError $ "Missing FQN:" <> show fqn

-- type Prop t =
--   { name :: String
--   , type :: t
--   , optional :: Boolean
--   }

-- tsClass fqn { bases, constructors, props } = do
--   withModule (ModulePath "Types.purs") \tps -> do
--     for props case _ of
--                   TsFunction args ret -> do
--
--                   _ -> traceM $ "Skipping non method during codegen of " <> show fqn
--
-- -- type Opts =
-- --   { foreignDeclarationModule :: Maybe
-- --   , classModule :: Nothing
-- --   }
--
-- -- tsClass :: TS.FullyQualifiedName -> _ -> _
-- -- tsClass = unsafePartial $ codegenModule "Data.Maybe" do
-- --
-- -- tsClass :: Module Void
-- -- tsClass = unsafePartial $ codegenModule "Data.Maybe" do
-- --   importOpen "Prelude"
-- --   tell
-- --     [ declData "Maybe" [ typeVar "a" ]
-- --         [ dataCtor "Nothing" []
-- --         , dataCtor "Just" [ typeVar "a" ]
-- --         ]
-- --
-- --     , declDerive Nothing []
-- --         (typeApp "Functor" [ typeCtor "Maybe" ])
-- --
-- --     , declSignature "maybe" do
-- --         typeForall [ typeVar "a", typeVar "b" ] do
-- --           typeArrow
-- --             [ typeVar "b"
-- --             , typeArrow [ typeVar "a" ] (typeVar "b")
-- --             , typeApp (typeCtor "Maybe") [ typeVar "a" ]
-- --             ]
-- --             (typeVar "b")
-- --     , declValue "maybe" [ binderVar "nothing", binderVar "just" ] do
-- --         exprCase [ exprSection ]
-- --           [ caseBranch [ binderCtor "Just" [ bindarVar "a" ] ] do
-- --               exprApp (exprIdent "just") [ exprIdent "a" ]
-- --           , caseBranch [ binderCtor "Nothing" [] ] do
-- --               exprIdent "nothing"
-- --           ]
-- --     ]
