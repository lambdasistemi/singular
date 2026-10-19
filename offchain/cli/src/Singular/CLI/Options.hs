{-# LANGUAGE ApplicativeDo #-}
{-# LANGUAGE LambdaCase #-}

{- |
Module      : Singular.CLI.Options
Description : Declare a program's commands once; read, document and complete them
License     : Apache-2.0

One declaration per program, written as data: its commands, and for each
command the settings it takes, each with its flag, metavariable,
description, default and environment variable. Everything a person sees is
generated from it by @opt-env-conf@, the library @moog@ uses:

* the one-screen overview, one page of help per command, and the usage line
  every refusal carries, with exclusive choices (a signer: the vault, an
  external address with its bundle, or a key file) shown as one group;
* the shell completion scripts and their queries;
* @--version@, with the identity line first on every help page.

A command line is read by the same library, flat: every flag a program
accepts is a setting, and a word is a word. Which flags a command refuses by
name, and everything else the command checks, stays with the command; this
module only reads and documents. Nothing here touches a file, a node or a
key.
-}
module Singular.CLI.Options
    ( -- * Declaring a program
      Program (..)
    , Node (..)
    , Leaf (..)
    , Shape (..)
    , Flag (..)
    , Accepted (..)
    , valued
    , switch'
    , standing
    , configFlag
    , defaultConfigFile
    , settingPrefix

      -- * Reading a command line
    , Raw (..)
    , Refusal (..)
    , readLine
    , refusalAs

      -- * What a person sees
    , identityLine
    , helpText
    , usageText
    , hintLines
    , resolvePath
    , commandPaths
    , nearestCommand
    , commandsBelow
    , leafAt
    , programLeaves
    , shapeFlags
    , shortenedExample
    , docParser
    , lintDeclaration

      -- * Completion
    , builtinCommand
    , completionsFor
    ) where

import Control.Monad (void)
import Data.Char (toUpper)
import Data.Foldable (traverse_)
import Data.List (isPrefixOf, nub, sortOn)
import Data.List.NonEmpty qualified as NE
import Data.Maybe (fromMaybe, isJust, isNothing, listToMaybe)
import Data.Text qualified as T
import Data.Version (Version, showVersion)
import System.Exit (ExitCode (..))
import System.IO.Unsafe (unsafePerformIO)

import OptEnvConf
    ( Parser
    , Reader
    , argument
    , choice
    , command
    , commands
    , conf
    , env
    , help
    , hidden
    , long
    , many
    , metavar
    , option
    , optional
    , reader
    , setting
    , short
    , str
    , switch
    , valueWithShown
    , withoutConfig
    )
import OptEnvConf.Args (parseArgs)
import OptEnvConf.Capability (allCapabilities)
import OptEnvConf.Completion
    ( Completion (..)
    , evalCompletions
    , generateBashCompletionScript
    , generateFishCompletionScript
    , generateZshCompletionScript
    , pureCompletionQuery
    , runCompletionQuery
    )
import OptEnvConf.Doc
    ( AnyDocs (..)
    , CommandDoc (..)
    , SetDoc
    , parserDocs
    , renderCommandHelpPage
    , renderHelpPage
    )
import OptEnvConf.EnvMap qualified as EnvMap
import OptEnvConf.Error
    ( ParseError (..)
    , ParseErrorMessage (..)
    )
import OptEnvConf.Lint (lintParser)
import OptEnvConf.Run (runParserOn)
import Path (parseAbsFile)
import Text.Colour (TerminalCapabilities (..), renderChunksText)

-- | Read a setting's value as the string it was given.
string :: Reader String
string = str

{- | One setting a command line can carry: its flag, what it is called in
the usage line, what it means, the default it takes and the environment
variable that names the same setting.
-}
data Flag = Flag
    { flagName :: String
    -- ^ The spelling, with its dashes: @--blueprint@
    , flagMetavar :: Maybe String
    -- ^ The value's name in the usage line; none for a switch
    , flagHelp :: String
    -- ^ One line saying what the setting is
    , flagDefault :: Maybe String
    -- ^ What is used when the flag is absent, as a person reads it
    , flagEnvironment :: Maybe String
    -- ^ The variable that supplies the setting when the flag is absent
    , flagConfig :: Maybe String
    -- ^ The key of the configuration file that supplies it when neither is given
    }
    deriving stock (Eq, Show)

-- | A flag that takes a value, given on the command line only.
valued :: String -> String -> String -> Flag
valued name meta text =
    Flag
        { flagName = name
        , flagMetavar = Just meta
        , flagHelp = text
        , flagDefault = Nothing
        , flagEnvironment = Nothing
        , flagConfig = Nothing
        }

{- | A flag that takes none. A switch changes what a command does, so it is
typed on the command it changes and has no other form.
-}
switch' :: String -> String -> Flag
switch' name text =
    Flag
        { flagName = name
        , flagMetavar = Nothing
        , flagHelp = text
        , flagDefault = Nothing
        , flagEnvironment = Nothing
        , flagConfig = Nothing
        }

{- | A standing setting: it has three forms, declared here once. The flag
@--koios-url@ is also the environment variable @SINGULAR_KOIOS_URL@ and the
key @koios-url@ of the configuration file. What a command line leaves out the
environment gives, and what both leave out the file gives.
-}
standing :: Flag -> Flag
standing flag =
    flag
        { flagEnvironment = Just (settingPrefix <> map shout name)
        , flagConfig = Just name
        }
  where
    name = drop 2 (flagName flag)
    shout = \case
        '-' -> '_'
        c -> toUpper c

-- | The start of every environment variable that names a setting.
settingPrefix :: String
settingPrefix = "SINGULAR_"

{- | The flag that names the configuration file, and the variable that does.
The file cannot name itself.
-}
configFlag :: Flag
configFlag =
    ( standing
        ( valued
            "--config"
            "FILE"
            "A JSON file giving the settings the command line and the environment leave out."
        )
    )
        { flagConfig = Nothing
        , flagDefault =
            Just "singular.json in the working directory, if there is one"
        }

-- | The configuration file a command reads when none is named.
defaultConfigFile :: FilePath
defaultConfigFile = "singular.json"

{- | How a command's settings fit together, as the usage line shows them:
required, optional, all of a few, or exactly one of several.
-}
data Shape
    = Needs Flag
    | Takes Flag
    | Each [Shape]
    | OneOf [Shape]
    deriving stock (Eq, Show)

-- | A command that does something.
data Leaf = Leaf
    { leafName :: String
    , leafSummary :: String
    -- ^ One line, as listed beside its siblings
    , leafDescription :: [String]
    -- ^ What it does, one paragraph each
    , leafShape :: Shape
    -- ^ The settings it takes
    , leafWord :: Maybe (String, String)
    -- ^ A positional argument it takes: its name and what it is
    , leafEnvironment :: [(String, String)]
    -- ^ Variables it reads that no setting names, with what they do
    , leafExamples :: [String]
    -- ^ Complete command lines, for a command that writes
    , leafNotes :: [String]
    -- ^ Exit statuses and outputs, one line each
    }
    deriving stock (Eq, Show)

-- | A command, or a group of commands.
data Node
    = -- | Name, one line, longer description, the commands inside it
      Group String String [String] [Node]
    | Runs Leaf
    deriving stock (Eq, Show)

{- | Every flag a program reads. The command line is read flat over these:
a command takes a subset and refuses the rest by name itself.
-}
data Accepted = Accepted
    { acceptedValued :: [String]
    -- ^ Flags that take the next word (or @=value@)
    , acceptedEarly :: [String]
    {- ^ Switches taken wherever they stand, a value position included,
    before any valued flag takes its word
    -}
    , acceptedSwitches :: [String]
    -- ^ Switches taken after the valued flags took theirs
    }
    deriving stock (Eq, Show)

-- | A program: its name, what it is for and its commands.
data Program = Program
    { programName :: String
    , programSummary :: String
    , programVersion :: Version
    , programNodes :: [Node]
    , programFooter :: [String]
    -- ^ Lines closing the overview
    }

{- | The variable that names the source revision a build was made from; the
commit the identity line shows, @unknown@ for a build that carries none.
-}
releaseCommitVariable :: String
releaseCommitVariable = "SINGULAR_RELEASE_COMMIT"

-- | The program's name, version and commit: the first line of every help page.
identityLine :: Program -> [(String, String)] -> String
identityLine program environment =
    unwords
        [ programName program
        , showVersion (programVersion program)
        , "(commit "
            <> fromMaybe "unknown" (lookup releaseCommitVariable environment)
            <> ")"
        ]

-- ---------------------------------------------------------------------------
-- Reading a command line

-- | A command line read flat: its words, and its flags in the order given.
data Raw = Raw
    { rawWords :: [String]
    , rawFlags :: [(String, Maybe String)]
    }
    deriving stock (Eq, Show)

-- | A token the program cannot take, named for the refusal that reports it.
data Refusal
    = Renamed String String
    | Removed String
    | NeedsValue String
    | UnknownFlag String
    deriving stock (Eq, Show)

-- | Say a refusal in a binary's own refusal type.
refusalAs
    :: (String -> e)
    -- ^ a removed setting
    -> (String -> String -> e)
    -- ^ a flag and what is wrong with it
    -> String
    -- ^ the program name, for the refusal naming the flags it reads
    -> Refusal
    -> e
refusalAs removed bad program = \case
    Renamed old new -> bad old ("was renamed to " <> new)
    Removed name -> removed name
    NeedsValue name -> bad name "needs a value"
    UnknownFlag name -> bad name ("is not a flag " <> program <> " reads")

{- | Read a command line over the flags a program accepts. A word is any
token that is not a flag it accepts, so a word that looks like a flag is
refused by its own name, in the order the command line gives them; a flag
that takes a value takes the next token whatever it looks like.
-}
readLine :: Accepted -> [String] -> Either Refusal Raw
readLine accepted args = unsafePerformIO $ do
    -- No file, terminal, environment or configuration is read by this
    -- parser, so running it is a function of the command line alone.
    result <-
        runParserOn
            allCapabilities
            Nothing
            (flatParser accepted)
            (parseArgs (map prepare args))
            EnvMap.empty
            Nothing
    pure $ case result of
        Right (ws, fs) -> classify accepted ws (map unmark' fs)
        Left errors -> case leftovers (NE.toList errors) of
            (w : _) -> Left (UnknownFlag (takeWhile (/= '=') w))
            [] -> Left (UnknownFlag "")
  where
    known = acceptedValued accepted
    switches = acceptedEarly accepted <> acceptedSwitches accepted
    -- Every token but the flags the program accepts becomes a plain word, so
    -- the library never has to guess whether one opens an option.
    prepare token
        | takeWhile (/= '=') token `elem` known = token
        | token `elem` switches = token
        | otherwise = marker : token
    unmark' (name, v) = (name, unmark <$> v)
    leftovers errors =
        [ w
        | ParseError _ (ParseErrorUnrecognised ws) <- errors
        , w <- NE.toList ws
        ]

-- | Marks a token the parser must take as a word.
marker :: Char
marker = '\1'

unmark :: String -> String
unmark = \case
    c : rest | c == marker -> rest
    other -> other

-- | The settings a flat read takes: every accepted flag, then the words.
flatParser :: Accepted -> Parser ([String], [(String, Maybe String)])
flatParser accepted = do
    early <- traverse switchFlag (acceptedEarly accepted)
    values <- traverse valuedFlag (acceptedValued accepted)
    late <- traverse switchFlag (acceptedSwitches accepted)
    ws <- many (setting [argument, reader string, metavar "WORD", hidden])
    pure (ws, concat early <> concat values <> concat late)
  where
    valuedFlag name = do
        found <-
            many
                ( setting
                    [ option
                    , reader string
                    , long (drop 2 name)
                    , metavar "VALUE"
                    , hidden
                    ]
                )
        pure [(name, Just v) | v <- found]
    switchFlag name = do
        found <-
            many
                ( setting
                    ( [switch (), hidden]
                        <> case name of
                            '-' : '-' : rest -> [long rest]
                            ['-', c] -> [short c]
                            _ -> []
                    )
                )
        pure [(canonical name, Nothing) | _ <- found]
    canonical name = if name == "-h" then "--help" else name

{- | The words and flags a token list gives: tokens carrying the marker are
words, and a word that spells a flag is refused by that flag's name.
-}
classify
    :: Accepted
    -> [String]
    -> [(String, Maybe String)]
    -> Either Refusal Raw
classify accepted ws fs = go ws []
  where
    go [] kept = Right (Raw (reverse kept) fs)
    go (w : rest) kept = case unmarked w of
        Nothing
            | w `elem` acceptedValued accepted -> Left (NeedsValue w)
            | otherwise -> go rest (w : kept)
        Just token
            | "--" `isPrefixOf` token -> case refuse token of
                Left refusal -> Left refusal
                Right extra -> goWith extra rest kept
            | otherwise -> go rest (token : kept)
    goWith extra rest kept = case go rest kept of
        Right (Raw ws' fs') -> Right (Raw ws' (extra <> fs'))
        Left refusal -> Left refusal
    unmarked = \case
        c : rest | c == marker -> Just rest
        _ -> Nothing
    refuse token
        | name == "--registry" = Left (Renamed "--registry" "--state-dir")
        | name `elem` ["--backend", "--node-socket"] = Left (Removed name)
        | name `elem` (acceptedSwitches accepted <> acceptedEarly accepted)
            && name /= "--json" =
            Right [(name, Nothing)]
        | name `elem` acceptedValued accepted = Left (NeedsValue name)
        | otherwise = Left (UnknownFlag name)
      where
        name = takeWhile (/= '=') token

-- ---------------------------------------------------------------------------
-- Documentation

{- | The program as documentation: every command with its settings arranged
as the usage line shows them. It is only ever rendered, never run.
-}
docParser :: Program -> Parser ()
docParser program = withoutConfig (commands (map node (programNodes program)))
  where
    node = \case
        Group name summary _ kids ->
            command name summary (commands (map node kids))
        Runs leaf ->
            command
                (leafName leaf)
                (leafSummary leaf)
                ( shape (Each [Takes configFlag, leafShape leaf])
                    *> maybe
                        (pure ())
                        ( \(meta, what) ->
                            void $ setting [argument, reader string, metavar meta, help what]
                        )
                        (leafWord leaf)
                )
    shape = \case
        Needs f -> one f
        Takes f -> optional' f
        Each ss -> traverse_ shape ss
        OneOf ss -> choice (map shape ss)
    one f = case flagMetavar f of
        Nothing -> void $ setting (common f <> [switch ()])
        Just meta ->
            void $
                setting
                    (common f <> inFile f <> [option, reader string, metavar meta])
    optional' f = case flagDefault f of
        Just shown
            | Just meta <- flagMetavar f ->
                void $
                    setting
                        ( common f
                            <> inFile f
                            <> [option, reader string, metavar meta, valueWithShown (const shown) ""]
                        )
        _ -> void (optional (one f))
    common f =
        [help (flagHelp f), long (drop 2 (flagName f))]
            <> maybe [] (\v -> [env v]) (flagEnvironment f)
    -- The key of the file shows beside the flag and the variable.
    inFile f = maybe [] (\k -> [conf k]) (flagConfig f)

-- | Whether the declaration is a well-formed parser for the library.
lintDeclaration :: Program -> Bool
lintDeclaration = isNothing . lintParser . docParser

-- | The words of a command line that name commands, as far as they go.
resolvePath :: Program -> [String] -> ([String], [String])
resolvePath program = go (programNodes program) []
  where
    go nodes path = \case
        w : rest
            | Just node <- listToMaybe [n | n <- nodes, nodeName n == w] ->
                case node of
                    Group _ _ _ kids -> go kids (path <> [w]) rest
                    Runs _ -> (path <> [w], rest)
        rest -> (path, rest)

nodeName :: Node -> String
nodeName = \case
    Group name _ _ _ -> name
    Runs leaf -> leafName leaf

-- | Every command and group a program names, by path; the overview is the empty path.
commandPaths :: Program -> [[String]]
commandPaths program = [] : concatMap (below []) (programNodes program)
  where
    below prefix = \case
        Runs leaf -> [prefix <> [leafName leaf]]
        Group name _ _ kids ->
            (prefix <> [name]) : concatMap (below (prefix <> [name])) kids

-- | The commands directly below a path.
commandsBelow :: Program -> [String] -> [String]
commandsBelow program path = map nodeName (nodesBelow program path)

nodesBelow :: Program -> [String] -> [Node]
nodesBelow program = go (programNodes program)
  where
    go nodes = \case
        [] -> nodes
        w : rest -> case [kids | Group name _ _ kids <- nodes, name == w] of
            kids : _ -> go kids rest
            [] -> []

-- | The command nearest to a mistyped word, if any is near.
nearestCommand :: [String] -> String -> Maybe String
nearestCommand candidates word =
    case sortOn fst [(distance word c, c) | c <- candidates] of
        (d, c) : _ | d <= max 2 (length word `div` 3) -> Just c
        _ -> Nothing

-- | Edit distance between two words.
distance :: String -> String -> Int
distance a b = last (foldl step [0 .. length a] b)
  where
    step previous@(p : ps) c =
        scanl compute (p + 1) (zip3 a previous ps)
      where
        compute left (x, diagonal, up) =
            minimum [up + 1, left + 1, diagonal + fromEnum (x /= c)]
    step [] _ = []

{- | The help page of a command (the overview for no path): the identity
line, the page the library draws from the declaration, then what the
declaration adds for a person: what the command does, the variables it
reads, examples and what it prints.
-}
helpText :: Program -> [(String, String)] -> [String] -> String
helpText program environment path =
    unlines . tidy . concat $
        [ [identityLine program environment, ""]
        , withDescription (pageLines program path)
        , extras
        ]
  where
    withDescription ls = case break (== "Available settings:") ls of
        (before, rest@(_ : _)) ->
            before
                <> concatMap (\p -> wrapText 78 0 p <> [""]) description
                <> rest
        (before, []) -> before
    description = case nodeAt program path of
        Just (Runs leaf) -> leafDescription leaf
        Just (Group _ _ paragraphs _) -> paragraphs
        Nothing -> []
    extras = case path of
        [] -> overview program
        _ -> case nodeAt program path of
            Just (Runs leaf) -> leafExtras leaf
            _ -> []

{- | The library's page for a command, wrapped to a terminal: the usage with
its continuation lines indented, every other long line broken at a space.
The overview drops the library's list of top-level commands, because it
lists every command itself.
-}
pageLines :: Program -> [String] -> [String]
pageLines program path =
    concatMap wrap
        . (if null path then dropSection "Available commands:" else id)
        . lines
        $ page
  where
    docs = parserDocs (docParser program)
    page = case path of
        [] ->
            T.unpack . renderChunksText WithoutColours $
                renderHelpPage
                    (programName program)
                    (programVersion program)
                    (programSummary program)
                    docs
        _ -> case findCommand path docs of
            Just doc ->
                T.unpack . renderChunksText WithoutColours $
                    renderCommandHelpPage
                        (programName program)
                        (init path)
                        doc
            Nothing -> ""
    wrap l
        | "Usage: " `isPrefixOf` l = wrapText 78 7 l
        | length l > 78 = wrapText 78 0 l
        | otherwise = [l]

-- | Take a section out of a page: its heading and what follows it.
dropSection :: String -> [String] -> [String]
dropSection heading ls = case break (== heading) ls of
    (before, _ : rest) -> before <> dropWhile (\l -> null l || " " `isPrefixOf` l) rest
    (before, []) -> before

-- | The usage line of a command, wrapped, for a refusal to show.
usageText :: Program -> [String] -> [String]
usageText program path =
    takeWhile (not . null) . dropWhile (not . isPrefixOf "Usage: ") $
        pageLines program path

{- | What a refusal adds below its own line: the nearest command when a word
was mistyped, the usage of the command the line was heading for, and where
its help is.
-}
hintLines :: Program -> [String] -> [String]
hintLines program args =
    concat
        [ suggestion
        , usageText program path
        , ["Try '" <> unwords (programName program : path) <> " --help'."]
        ]
  where
    (path, rest) = resolvePath program (takeWhile (not . isFlag) args)
    isFlag = ("-" `isPrefixOf`)
    suggestion = case rest of
        w : _
            | Just c <- nearestCommand (commandsBelow program path) w ->
                [ "Did you mean `"
                    <> unwords (programName program : path <> [c])
                    <> "`?"
                ]
        _ -> []

nodeAt :: Program -> [String] -> Maybe Node
nodeAt program = go (programNodes program)
  where
    go nodes = \case
        [] -> Nothing
        [w] -> listToMaybe [n | n <- nodes, nodeName n == w]
        w : rest -> case [kids | Group name _ _ kids <- nodes, name == w] of
            kids : _ -> go kids rest
            [] -> Nothing

findCommand
    :: [String]
    -> AnyDocs (Maybe SetDoc)
    -> Maybe (CommandDoc (Maybe SetDoc))
findCommand path = \case
    AnyDocsCommands _ cs -> case path of
        [] -> Nothing
        w : rest -> case [c | c <- cs, commandDocArgument c == w] of
            c : _
                | null rest -> Just c
                | otherwise -> findCommand rest (commandDocs c)
            [] -> Nothing
    AnyDocsAnd ds -> listToMaybe [c | d <- ds, Just c <- [findCommand path d]]
    AnyDocsOr ds -> listToMaybe [c | d <- ds, Just c <- [findCommand path d]]
    AnyDocsSingle _ -> Nothing

{- | Break a line at spaces to a width, keeping its indentation and indenting
the continuation lines by a further hang.
-}
wrapText :: Int -> Int -> String -> [String]
wrapText width hang line = go (words line) "" []
  where
    indent = takeWhile (== ' ') line
    continuation = indent <> replicate hang ' '
    go [] current acc = reverse (if null current then acc else current : acc)
    go (w : ws) current acc
        | null current = go ws (indent <> w) acc
        | length current + 1 + length w > width =
            go ws (continuation <> w) (current : acc)
        | otherwise = go ws (current <> " " <> w) acc

-- | One blank line between sections, none at the ends.
tidy :: [String] -> [String]
tidy = dropTrailing . collapse
  where
    collapse = \case
        "" : "" : rest -> collapse ("" : rest)
        l : rest -> l : collapse rest
        [] -> []
    dropTrailing = reverse . dropWhile null . reverse

overview :: Program -> [String]
overview program =
    concat
        [ ["", "All commands:"]
        , concatMap (flatten []) (programNodes program)
        , [""]
        , ["Help on one command: " <> name <> " COMMAND --help"]
        ,
            [ "Shell completion (bash): source <("
                <> name
                <> " --bash-completion-script \"$(which "
                <> name
                <> ")\")"
            ]
        ,
            [ "  zsh and fish: --zsh-completion-script and --fish-completion-script instead."
            ]
        , programFooter program
        ]
  where
    name = programName program
    flatten prefix = \case
        Runs leaf -> [line (prefix <> [leafName leaf]) (leafSummary leaf)]
        Group group _ _ kids -> concatMap (flatten (prefix <> [group])) kids
    line path summary =
        "  " <> pad 28 (unwords (name : path)) <> summary
    pad n s = s <> replicate (n - length s) ' '

leafExtras :: Leaf -> [String]
leafExtras leaf =
    concat
        [ section "Where settings come from" settingSources
        , section
            "Environment"
            (concatMap environmentLines (leafEnvironment leaf))
        , section
            "Example"
            ( map ("  " <>) (leafExamples leaf)
                <> shortExample standings (leafExamples leaf)
            )
        , section
            "Output and exit status"
            (concatMap (wrapText 78 0 . ("  " <>)) (leafNotes leaf))
        ]
  where
    standings =
        [ f | f <- nub (shapeFlags (leafShape leaf)), isJust (flagEnvironment f)
        ]
    settingSources
        | null standings = []
        | otherwise =
            paragraph
                "A setting with an env and a config line above is given in any of three ways, and the first that is present wins: the flag, then the variable, then the key in the config file, then the default."
                <> paragraph
                    "The file is one JSON object whose keys are the setting names without their dashes, text or numbers, for example"
                <> [ "    {\"koios-url\": \"https://preprod.koios.rest/api/v1\", \"network-magic\": 1}"
                   , ""
                   ]
                <> paragraph
                    ( "It is "
                        <> defaultConfigFile
                        <> " in the working directory, or the file named by --config or "
                        <> fromMaybe "SINGULAR_CONFIG" (flagEnvironment configFlag)
                        <> ". A path in it means what it means on the command line, from where the command runs. A passphrase is never read from the file or the environment: it stays on the prompt or --passphrase-fd."
                    )
    paragraph text = wrapText 78 0 ("  " <> text) <> [""]
    section title body
        | null body = []
        | otherwise = "" : (title <> ":") : body
    width = maximum (0 : map (length . fst) (leafEnvironment leaf)) + 2
    environmentLines (name, what) = case wrapText (76 - width) 0 what of
        first : rest ->
            ("  " <> name <> replicate (width - length name) ' ' <> first)
                : map (replicate (2 + width) ' ' <>) rest
        [] -> ["  " <> name]

{- | An example command again with the standing settings it names left to the
config file: the same words with those flags and their values taken out, laid
out afresh. Nothing when the example names none.
-}
shortExample :: [Flag] -> [String] -> [String]
shortExample standings example = case shortenedExample standings example of
    Nothing -> []
    Just shortLines ->
        ""
            : ("  With those settings in " <> defaultConfigFile <> " instead:")
            : map ("  " <>) shortLines

{- | The lines of an example without the standing settings it names, or
nothing when it names none.
-}
shortenedExample :: [Flag] -> [String] -> Maybe [String]
shortenedExample standings example
    | null example || length kept == length tokens = Nothing
    | otherwise = Just (layout kept)
  where
    tokens = filter (/= "\\") (words (unwords example))
    names = map flagName standings
    kept = dropSettings tokens
    dropSettings = \case
        token : _ : rest | token `elem` names -> dropSettings rest
        token : rest -> token : dropSettings rest
        [] -> []
    layout = fill "" . pairUp
    -- A flag stays on the line with its value.
    pairUp = \case
        flag : value : rest
            | "--" `isPrefixOf` flag && not ("--" `isPrefixOf` value) ->
                (flag <> " " <> value) : pairUp rest
        token : rest -> token : pairUp rest
        [] -> []
    fill current = \case
        [] -> [current | not (null current)]
        w : ws
            | null current -> fill w ws
            | length current + 1 + length w > 68 ->
                (current <> " \\") : fill ("    " <> w) ws
            | otherwise -> fill (current <> " " <> w) ws

-- ---------------------------------------------------------------------------
-- Completion

{- | What completion offers for the word at an index of the words typed so
far, the program name left out.
-}
completionsFor :: Program -> [String] -> Int -> IO [String]
completionsFor program ws index = do
    found <-
        evalCompletions
            arg
            (pureCompletionQuery (docParser program) index ws)
    pure (map completionSuggestion found)
  where
    arg = fromMaybe "" (listToMaybe (drop index ws))

{- | The commands every program built on this module answers before it reads
a command line: the completion scripts and the completion query the scripts
make. Nothing else is taken: the command line otherwise goes to the command.
-}
builtinCommand :: Program -> [String] -> IO (Maybe ExitCode)
builtinCommand program = \case
    ["--bash-completion-script", p]
        | Just path <- parseAbsFile p ->
            done (generateBashCompletionScript path name)
    ["--zsh-completion-script", p]
        | Just path <- parseAbsFile p ->
            done (generateZshCompletionScript path name)
    ["--fish-completion-script", p]
        | Just path <- parseAbsFile p ->
            done (generateFishCompletionScript path name)
    "--query-opt-env-conf-completion" : rest -> case query False rest of
        Just (enriched, index, ws) ->
            done (runCompletionQuery (docParser program) enriched index ws)
        Nothing -> pure Nothing
    _ -> pure Nothing
  where
    name = programName program
    done act = act >> pure (Just ExitSuccess)
    query enriched = \case
        "--completion-enriched" : rest -> query True rest
        "--completion-index" : n : rest
            | [(index, "")] <- reads n -> Just (enriched, index, words' rest)
        _ -> Nothing
    words' = \case
        "--completion-word" : w : rest -> w : words' rest
        _ -> []

-- ---------------------------------------------------------------------------
-- Looking into a declaration

-- | The command a path names, when it is one that runs.
leafAt :: Program -> [String] -> Maybe Leaf
leafAt program path = case nodeAt program path of
    Just (Runs leaf) -> Just leaf
    _ -> Nothing

-- | Every command of a program that runs.
programLeaves :: Program -> [Leaf]
programLeaves program = concatMap below (programNodes program)
  where
    below = \case
        Runs leaf -> [leaf]
        Group _ _ _ kids -> concatMap below kids

-- | Every flag a shape names, in the order it names them.
shapeFlags :: Shape -> [Flag]
shapeFlags = \case
    Needs f -> [f]
    Takes f -> [f]
    Each ss -> concatMap shapeFlags ss
    OneOf ss -> concatMap shapeFlags ss
