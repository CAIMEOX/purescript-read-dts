module ReadDTS.TypeScript.Testing where

import Prelude

import Data.Array (any, cons) as Array
import Data.Array (find)
import Data.List (List)
import Data.Maybe (Maybe(..))
import Data.Traversable (for)
-- import Data.Tuple ((/\))
import Data.Undefined.NoProblem (Opt, opt, undefined)
import Debug (traceM)
import Effect (Effect)
import Effect.Exception (throw)
import Effect.Uncurried (EffectFn1, EffectFn2, EffectFn3, mkEffectFn1, mkEffectFn2, mkEffectFn3, runEffectFn1, runEffectFn2)
import Node.Buffer (toString) as Buffer
import Node.Encoding (Encoding(..))
import Node.FS.Sync (exists, readFile)
import Node.Path (FilePath, basename, dirname)
import TypeScript.Compiler.Parser (FileName, SourceCode, createSourceFile)
import TypeScript.Compiler.Types (CompilerHost, CompilerOptions, Program, ScriptTarget, scriptTarget)
import TypeScript.Compiler.Types.Nodes (SourceFile)
import TypeScript.Compiler.Types.Nodes (interface) as Node
import Unsafe.Coerce (unsafeCoerce)

type DirName = String
type WriteByteOrderMark = Boolean

type WriteFileCallback = EffectFn3 FileName SourceCode WriteByteOrderMark Unit

type CompilerHost' =
  { directoryExists :: Opt (EffectFn1 DirName Boolean)
  , fileExists :: EffectFn1 FileName Boolean
  , getCanonicalFileName :: EffectFn1 FileName FileName
  , getCurrentDirectory :: Opt (Effect String)
  , getDefaultLibFileName :: EffectFn1 CompilerOptions FileName
  , getDirectories :: Opt (EffectFn1 String (Array String))
  , getNewLine :: Effect String
  , getSourceFile :: EffectFn2 FileName ScriptTarget (Opt SourceFile)
  , readFile :: EffectFn1 FileName (Opt SourceCode)
  , useCaseSensitiveFileNames :: Effect Boolean
  , writeFile :: WriteFileCallback
  }

foreign import bindCompilerHost :: CompilerHost -> CompilerHost'

toCompilerHost :: CompilerHost' -> CompilerHost
toCompilerHost = unsafeCoerce

type InMemoryFile = { path :: FileName, source :: SourceCode }

handleMemoryFiles :: CompilerHost -> Array InMemoryFile -> Effect CompilerHost
handleMemoryFiles realHost inMemoryFiles = do
  sourceFiles <- for inMemoryFiles \{ path, source } -> do
    createSourceFile path source scriptTarget."ES5" true

  let
    paths = map _.path inMemoryFiles
    realHost' = bindCompilerHost realHost

    host :: CompilerHost'
    host = realHost'
      { fileExists = mkEffectFn1 \p ->
          ((Array.any (eq p) paths) || _) <$> runEffectFn1 realHost'.fileExists p
      , getSourceFile = mkEffectFn2 \fileName scriptTarget -> do
          case find (eq fileName <<< _.fileName <<< Node.interface) sourceFiles of
            Just sourceFile -> pure $ opt sourceFile
            Nothing -> runEffectFn2 realHost'.getSourceFile fileName scriptTarget
      , readFile = mkEffectFn1 \fileName -> do
          case find (eq fileName <<< _.fileName <<< Node.interface) sourceFiles of
            Just sourceFile -> pure $ opt (Node.interface sourceFile # _.text)
            Nothing -> runEffectFn1 realHost'.readFile fileName
      , writeFile = mkEffectFn3 (\_ _ _ -> pure unit)
      }
  pure $ toCompilerHost host

inMemoryCompilerHost :: Array InMemoryFile -> FilePath -> Effect CompilerHost
inMemoryCompilerHost inMemoryFiles defaultLibFile = do
  defaultLibFileSrc <- exists defaultLibFile >>= if _
    then do
      b <- readFile defaultLibFile
      Buffer.toString UTF8 b
    else
      throw $
        "inMemoryCompilerHost: Unable to find default `CompilerHost` library file:" <> defaultLibFile
  let
    inMemoryFiles' = Array.cons
      { path: defaultLibFile, source: defaultLibFileSrc }
      inMemoryFiles

  sourceFiles <- for inMemoryFiles' \{ path, source } -> do
    file <- createSourceFile path source scriptTarget."ES5" true
    pure { path, source, file }
  let
    host :: CompilerHost'
    host =
      { fileExists: mkEffectFn1 \p -> pure (Array.any (eq p <<< _.path) sourceFiles)
      , directoryExists: opt $ mkEffectFn1 \d -> pure (d == "/")
      , getCurrentDirectory: opt $ pure "/"
      , getDirectories: opt $ mkEffectFn1 $ const (pure [])
      , getCanonicalFileName: mkEffectFn1 pure
      , getNewLine: pure "\n"
      , getDefaultLibFileName: mkEffectFn1 (const $ pure defaultLibFile)
      , getSourceFile: mkEffectFn2 \fileName _ -> do
          case find (eq fileName <<< _.path) sourceFiles of
            Just { file } -> pure $ opt file
            Nothing -> pure undefined
      , readFile: mkEffectFn1 \fileName -> do
          case find (eq fileName <<< _.path) sourceFiles of
            Just { source } -> pure $ opt source
            Nothing -> pure undefined
      , useCaseSensitiveFileNames: pure true
      , writeFile: mkEffectFn3 (\_ _ _ -> pure unit)
      }
  pure $ toCompilerHost host

-- exportedNodes :: forall d t. Program -> List (SourceFile /\ List (Node ()))
-- exportedNodes program visit = do
--   let
--     checker = getTypeChecker program
--     rootNames = getRootFileNames program
--     fileName = Node.interface >>> _.fileName
--     rootFiles = Array.filter ((\fn -> fn `Array.elem` rootNames) <<< fileName) $ getSourceFiles program
--   -- | `SourceFile` "usually" has as a single root child of type `SyntaxList`.
--   -- | * We are not interested in this particular child.
--   -- | * We should probably recurse into any container like
--   -- node (`Block`, `ModuleDeclaration` etc.) down the stream too.
--   rootFiles >>= traverse_ \sf -> do
--     nodes <- for (getChildren sf >>= getChildren) \node -> do
--       when (isNodeExported checker node) do
--         pure node
--     pure $ sf /\ nodes
-- --   
-- --   traceM $ "Reading node: " <> showSyntaxKind node
-- --   case readDeclaration checker node visit of
-- --     Just (fqn /\ d) -> modify_ (Map.insert fqn d)
-- --     Nothing -> do
-- --       traceM "Unable to parse node as declaration. Skipping node..."
-- 
