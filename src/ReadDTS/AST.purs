module ReadDTS.AST where

import Prelude

import Control.Alt ((<|>))
import Control.Monad.Error.Class (class MonadError, throwError)
import Control.Monad.Except (runExceptT)
import Control.Monad.Free (Free, wrap)
import Control.Monad.Rec.Loops (whileJust_)
import Control.Monad.State (execStateT)
import Data.Array (catMaybes, length) as Array
import Data.Array.NonEmpty (NonEmptyArray)
import Data.Array.NonEmpty (fromArray) as Array.NonEmpty
import Data.Bifoldable (class Bifoldable, bifoldMap, bifoldlDefault, bifoldrDefault)
import Data.Bifunctor (class Bifunctor, lmap)
import Data.Either (Either)
import Data.Eq (class Eq1)
import Data.Foldable (class Foldable, foldMap, foldlDefault, foldrDefault, length)
import Data.Functor.Mu (Mu(..)) as Mu
import Data.Functor.Mu (Mu)
import Data.Generic.Rep (class Generic)
import Data.Identity (Identity(..))
import Data.Lens (use)
import Data.Lens.Record (prop)
import Data.Lens.Setter ((%=), (.=))
import Data.List (List(..), catMaybes, fromFoldable, length, singleton) as List
import Data.List (List, (:))
import Data.Maybe (Maybe(..))
import Data.Newtype (un)
import Data.Profunctor.Strong ((&&&))
import Data.Set (fromFoldable, insert, member) as Set
import Data.Show.Generic (genericShow)
import Data.Traversable (class Traversable, for, sequence, traverse, traverseDefault)
import Data.Tuple (fst)
import Data.Tuple.Nested ((/\), type (/\))
import Debug (traceM)
import Matryoshka (cata, futuM)
import ReadDTS (Args, Params, Prop, Props, asTypeRef, readDeclaration, readInnerType, readTopLevelType, sequenceArg, sequenceProp) as ReadDTS
import ReadDTS (Param, Params(..), Visit, fqnToString, readInnerType, readRootDeclarationNodes)
import ReadDTS.TypeScript (getDeclarationStatementFqn)
import Type.Prelude (Proxy(..))
import TypeScript.Compiler.Program (getTypeChecker)
import TypeScript.Compiler.Types (FullyQualifiedName(..), Program, Typ, TypeChecker)
import TypeScript.Compiler.Types (Typ) as TS
import TypeScript.Compiler.Types.Nodes (DeclarationStatement) as Nodes
import TypeScript.Debug (formatNodeFlags, formatNodeFlags')
import Unsafe.Coerce (unsafeCoerce)
import Unsafe.Reference (unsafeRefEq)

type Prop decl ref = ReadDTS.Prop (TsType decl ref)

-- | We want this wrapper so we are able to provide basic instances
-- | for it.
-- | Some of them are just required for testing purposes.
newtype TSTyp = TSTyp (TS.Typ ())

instance Show TSTyp where
  show (TSTyp _) = "TSTyp"

instance Eq TSTyp where
  eq (TSTyp t1) (TSTyp t2) = unsafeRefEq t1 t2

data TsType decl ref
  = TsAny
  | TsApplication decl (NonEmptyArray ref)
  | TsArray ref
  | TsBoolean
  | TsBooleanLiteral Boolean
  | TsClass (ReadDTS.Props ref)
  | TsFunction (ReadDTS.Args ref) ref
  | TsInterface (ReadDTS.Props ref)
  | TsIntersection (Array ref)
  | TsNull
  | TsNumber
  | TsNumberLiteral Number
  | TsObject (ReadDTS.Props ref)
  | TsString
  | TsStringLiteral String
  | TsTuple (Array ref)
  | TsParametric ref (ReadDTS.Params ref)
  | TsParameter String
  | TsTypeRef decl
  | TsUndefined
  | TsUnion (Array ref)
  | TsUnknown TSTyp

-- | TsVoid

derive instance functorTsType :: Functor (TsType decl)
derive instance eqTsType :: (Eq decl, Eq ref) => Eq (TsType decl ref)
instance eq1TsType :: Eq decl => Eq1 (TsType decl) where
  eq1 = eq

derive instance genericTsType :: Generic (TsType decl ref) _
instance showTsType :: (Show decl, Show ref) => Show (TsType decl ref) where
  show s = genericShow s

instance Bifunctor TsType where
  bimap f g (TsApplication decl ref) = TsApplication (f decl) (map g ref)
  bimap f _ (TsTypeRef decl) = TsTypeRef (f decl)
  bimap _ g t = unsafeCoerce (map g t)

instance Foldable (TsType decl) where
  foldMap _ TsAny = mempty
  foldMap f (TsArray t) = f t
  foldMap _ TsBoolean = mempty
  foldMap _ (TsBooleanLiteral _) = mempty
  foldMap f (TsClass ts) = foldMap (f <<< _.type) ts
  foldMap f (TsFunction args r) = foldMap (f <<< _.type) args <> f r
  foldMap f (TsInterface ts) = foldMap (f <<< _.type) ts
  -- foldMap f (Intersection ts) = fold (map (foldMap f) ts)
  foldMap f (TsApplication _ ps) = foldMap f ps
  foldMap f (TsIntersection ts) = foldMap f ts
  foldMap _ TsNull = mempty
  foldMap _ TsNumber = mempty
  foldMap _ (TsNumberLiteral _) = mempty
  foldMap f (TsObject ts) = foldMap (f <<< _.type) ts
  foldMap _ (TsParameter _) = mempty
  foldMap f (TsParametric body params) = f body <> foldMap f params
  foldMap _ TsString = mempty
  foldMap _ (TsStringLiteral _) = mempty
  foldMap f (TsTuple ts) = foldMap f ts
  foldMap _ (TsTypeRef _) = mempty
  foldMap _ TsUndefined = mempty
  foldMap f (TsUnion ts) = foldMap f ts
  foldMap _ (TsUnknown _) = mempty
  foldr f t = foldrDefault f t
  foldl f t = foldlDefault f t

instance Bifoldable TsType where
  bifoldMap f _ (TsApplication decl _) = f decl
  bifoldMap f _ (TsTypeRef decl) = f decl
  bifoldMap _ g t = unsafeCoerce (foldMap g t)
  bifoldr f = bifoldrDefault f
  bifoldl f = bifoldlDefault f

instance Traversable (TsType decl) where
  sequence TsAny = pure TsAny
  sequence (TsApplication decl ps) = TsApplication decl <$> sequence ps
  sequence (TsArray t) = TsArray <$> t
  sequence TsBoolean = pure TsBoolean
  sequence (TsBooleanLiteral b) = pure $ TsBooleanLiteral b
  sequence (TsClass props) = map TsClass $ sequence $ map ReadDTS.sequenceProp props
  sequence (TsFunction args r) = TsFunction
    <$> traverse ReadDTS.sequenceArg args
    <*> r
  sequence (TsInterface props) = map TsInterface $ sequence $ map ReadDTS.sequenceProp props
  sequence (TsIntersection ts) = TsIntersection <$> sequence ts
  sequence TsNull = pure TsNull
  sequence TsNumber = pure $ TsNumber
  sequence (TsNumberLiteral n) = pure $ TsNumberLiteral n
  sequence (TsObject props) = map TsObject $ sequence $ map ReadDTS.sequenceProp props
  sequence (TsParameter t) = pure $ TsParameter t
  sequence (TsParametric body params) = TsParametric
    <$> body
    <*> sequence params
  sequence TsString = pure $ TsString
  sequence (TsStringLiteral s) = pure $ TsStringLiteral s
  sequence (TsTuple ts) = TsTuple <$> sequence ts
  sequence (TsTypeRef decl) = pure $ TsTypeRef decl
  sequence TsUndefined = pure TsUndefined
  sequence (TsUnion ts) = TsUnion <$> sequence ts
  sequence (TsUnknown t) = pure $ TsUnknown t
  --   sequence Void = pure Void
  traverse = traverseDefault

type Typ' = TsType TsRef (Typ ())

type TypeDeclaration t = { fqn :: FullyQualifiedName, "type" :: t }

type TsRef =
  { ref :: Nodes.DeclarationStatement
  , fullyQualifiedName :: FullyQualifiedName
  }

visitor :: Visit (TypeDeclaration Typ') Typ'
visitor =
  { onDeclaration: { fqn: _, "type": _ }
  , onType:
      { any: TsAny
      , application: \fqn ref args ->
          TsApplication { fullyQualifiedName: fqn, ref } args
      , array: TsArray
      , boolean: TsBoolean
      , booleanLiteral: TsBooleanLiteral
      , class: TsClass
      , function: TsFunction
      , intersection: TsIntersection
      , interface: TsInterface
      , object: TsObject
      , null: TsNull
      , number: TsNumber
      , numberLiteral: TsNumberLiteral
      , parameter: TsParameter
      , parametric: TsParametric
      , string: TsString
      , stringLiteral: TsStringLiteral
      , tuple: TsTuple
      , typeRef: map TsTypeRef <<< { fullyQualifiedName: _, ref: _ }
      , undefined: TsUndefined
      , unknown: TsUnknown <<< TSTyp
      , union: TsUnion
      }
  }

foldMapRec :: forall a m. Monoid m => (a -> m) -> Mu (TsType a) -> m
foldMapRec f = cata (bifoldMap f identity)

mapRec :: forall a b. (a -> b) -> Mu (TsType a) -> Mu (TsType b)
mapRec f = cata $ Mu.In <<< lmap f

type Decl = { fullyQualifiedName :: FullyQualifiedName, ref :: Nodes.DeclarationStatement }

type Seed = { level :: Int, ref :: Typ () }

type ReadTsType m = Seed -> m (TsType Decl (TS.Typ ()))

-- | Our unfold step function which handles some initial corner cases.
-- |
-- | * We want to "resolve" type ref during the top layer read
-- | because a lot of types are type refs (like arrays, tuples or
-- | even class/interface declaration) so we run `readTypeRef` only
-- | when `level > 0`.
-- |
-- | * We have to unfold manually parametric type because I have not found
-- | a way to properly detect and disambiguate this case based only on
-- | the `Typ ()` (it is self referencing `typeReference`...)
mkCoalgebra
  :: forall m
   . MonadError (Array String) m
  => Int
  -> TypeChecker
  -> Maybe (Params (Typ ()))
  -> (Seed -> m (TsType Decl (Free (TsType Decl) Seed)))
mkCoalgebra maxDepth checker params seed = do
  -- FIXME: We should probably provide a dedicated constructor
  -- for *unread* scenario - probably a different one than
  -- `TsUnknown` because ts complier possibly uses that.
  if (seed.level > maxDepth) then pure (TsUnknown $ TSTyp seed.ref)
  -- throwError [ "Maximum recursion depth (max depth is " <> show maxDepth <> ") in ReadDTS.AST.visitor coalgebra" ]
  else do

    let
      mkSeed = { level: seed.level + 1, ref: _ }

      mapSeed :: forall decl. TsType decl (Typ ()) -> TsType decl (Free (TsType decl) Seed)
      mapSeed = map (pure <<< mkSeed)

      readTopLevelType ref = mapSeed $ ReadDTS.readTopLevelType checker ref visitor.onType

      readInnerType ref = mapSeed $ ReadDTS.readInnerType checker ref visitor.onType

    pure $
      if seed.level == 0 then case params of
        Just params' -> do
          TsParametric
            (wrap $ readTopLevelType seed.ref)
            (map (wrap <<< readInnerType) params')
        Nothing ->
          readTopLevelType seed.ref
      else readInnerType seed.ref

unfoldType
  :: forall m
   . MonadError (Array String) m
  => TypeChecker
  -> Maybe (Params (Typ ()))
  -> Seed
  -> m (Mu (TsType Decl))
unfoldType checker params = futuM (mkCoalgebra 3 checker params)

types :: Program -> Either (Array String) (List (FullyQualifiedName /\ Mu (TsType FullyQualifiedName)))
types program = un Identity $ runExceptT do
  let
    _unknowns = prop (Proxy :: Proxy "unknowns")
    _knowns = prop (Proxy :: Proxy "knowns")
    _seen = prop (Proxy :: Proxy "seen")

    checker = getTypeChecker program
    roots = List.fromFoldable $ readRootDeclarationNodes program

    x = do
      traceM "root declaration statement"
      traceM $ List.length roots
      Nothing

    -- FIXME: We are skipping declarations for which we were not
    -- able to extract fqn. This should be reported for sure.
    step decl = do
      fqn <- getDeclarationStatementFqn checker decl
      pure $ fqn /\ decl
    unknowns = List.catMaybes $ map step roots
    ctx =
      { unknowns
      , knowns: List.Nil
      , seen: Set.fromFoldable $ map fst unknowns
      }

    getUnknown = do
      use _unknowns >>= case _ of
        head : tail -> do
          _unknowns .= tail
          pure $ Just head
        List.Nil -> pure Nothing

    foldTypeDecls = foldMapRec (\{ fullyQualifiedName: fqn, ref } -> List.singleton (fqn /\ ref))
    stripTypeRefs = mapRec _.fullyQualifiedName

  map _.knowns $ flip execStateT ctx $ whileJust_ getUnknown \(fqn /\ node) -> do
    case ReadDTS.readDeclaration checker node of
      Nothing -> throwError [ "Problem reading " <> fqnToString fqn ]
      Just { typ, params } -> do
        type_ <- unfoldType checker params { level: 0, ref: typ }

        _knowns %= List.Cons (fqn /\ stripTypeRefs type_)
        for (foldTypeDecls type_) \decl@(fqn' /\ _) -> do
          seen <- use _seen
          when (not $ fqn' `Set.member` seen) do
            _seen %= Set.insert fqn'
            _unknowns %= List.Cons decl
