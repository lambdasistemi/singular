{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE LambdaCase #-}

-- | @vector-drift-check@ (issue #49): is the vendored v0.2.0 wire copy
-- still what the live corpus ships?
--
-- The four epic-15 wire vectors exist twice by design (D-016): pinned
-- byte-for-byte in @Naming.Wire.Vectors@ with their provenance, and
-- live in epic 15's merged corpus @lean\/lifecycle-corpus.json@. The
-- pin is deliberate — Singular implements the accepted v0.2.0 release,
-- not whatever the live file becomes. The cost is a blind spot: if
-- epic 15 revises its corpus, nothing says so. This check says so.
--
-- What it compares: every value the vendored module pins, against the
-- corresponding field of the corpus row with the same id — five wire
-- byte arrays, WD01's fixture and shape, WD02's attachment hash, WD03's
-- encoded datum, and WR01's proposal, shape, comparison result and
-- refund addresses. Divergence is REPORTED, never resolved: this check
-- never writes the vendored bytes and never re-points the suite at the
-- live file. A human decides whether to adopt the new contract.
--
-- Output markers (for the gate and for readers):
--
--   * @vector-drift-check@ — this check;
--   * @drift-pinned-release@ — the release the vendored copy is pinned
--     to, parsed from the vendored module's own provenance header;
--   * @drift-live-corpus@ — the live file it compared against.
--
-- Exit codes: 0 = in agreement; 1 = drift reported; 2 = the check
-- itself could not run (bad usage, unreadable inputs, missing pin, or
-- a corpus this reader cannot read).
--
-- Pure base + bytestring: no cabal, no package index, no network (the
-- D-011 logic of the naming suite, at the same unit-test cost). The
-- corpus side is read with a minimal JSON reader rather than pulling a
-- dependency: the corpus is machine-generated, and any structural
-- change to it must surface as either a clean comparison or a loud
-- parse failure — never as a silent pass.
module Main (main) where

import Control.Monad (forM_, unless)
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.Char (isDigit, isHexDigit)
import Data.List (group, intercalate, sort, stripPrefix)
import Data.Maybe (mapMaybe)
import Data.Word (Word8)

import Naming.Datum
    ( DatumAttachment (..)
    , DatumShape (..)
    , NamingDatum (..)
    , PaymentDestination (..)
    , RetirementQuorum (..)
    )
import Naming.Request
    ( InitialOutput (..)
    , InsertProposal (..)
    , InsertRequestShape (..)
    , RefundComparison (..)
    , Representative (..)
    , refundReasonText
    )
import Naming.Wire
    ( Address (..)
    , AddressForm (..)
    , PaymentCredential (..)
    , WireData (..)
    )
import Naming.Wire.Vectors
    ( wd01ExpectedBytes
    , wd01Fixture
    , wd01Id
    , wd01MalformedBytes
    , wd01Shape
    , wd02Attachment
    , wd02Id
    , wd03Encoded
    , wd03Id
    , wr01ComparisonResult
    , wr01ExpectedBytes
    , wr01Id
    , wr01MalformedBytes
    , wr01PresentedRefundAddress
    , wr01RedirectedBytes
    , wr01Shape
    , wr01StoredProposal
    , wr01StoredRefundAddress
    )
import System.Directory (doesFileExist)
import System.Environment (getArgs)
import System.Exit (ExitCode (..), exitFailure, exitSuccess, exitWith)
import System.IO (hPutStrLn, stderr)

--------------------------------------------------------------------------------
-- The corpus's own JSON, read minimally
--------------------------------------------------------------------------------

-- | The subset of JSON the corpus uses. The corpus is jq-generated
-- from integer data, so numbers are integers; anything else fails the
-- check loudly rather than passing silently.
data JValue
  = JNull
  | JBool Bool
  | JNum Integer
  | JStr String
  | JArr [JValue]
  | JObj [(String, JValue)]
  deriving stock (Eq, Show)

parseJson :: String -> Either String JValue
parseJson input = case pValue (ws input) of
  Left err -> Left err
  Right (v, rest) -> case ws rest of
    [] -> Right v
    _ -> Left "trailing content after the top-level JSON value"

ws :: String -> String
ws = dropWhile (\c -> c == ' ' || c == '\t' || c == '\n' || c == '\r')

pValue :: String -> Either String (JValue, String)
pValue input = case input of
  [] -> Left "unexpected end of input"
  '{' : rest -> pObject (ws rest) []
  '[' : rest -> pArray (ws rest) []
  '"' : rest -> do
    (s, rest') <- pString rest ""
    pure (JStr s, rest')
  't' : 'r' : 'u' : 'e' : rest -> pure (JBool True, rest)
  'f' : 'a' : 'l' : 's' : 'e' : rest -> pure (JBool False, rest)
  'n' : 'u' : 'l' : 'l' : rest -> pure (JNull, rest)
  _ -> pNumber input

pObject :: String -> [(String, JValue)] -> Either String (JValue, String)
pObject input acc = case input of
  '}' : rest -> pure (JObj (reverse acc), rest)
  '"' : rest -> do
    (k, rest1) <- pString rest ""
    case ws rest1 of
      ':' : rest2 -> do
        (v, rest3) <- pValue (ws rest2)
        case ws rest3 of
          ',' : rest4 -> pObject (ws rest4) ((k, v) : acc)
          '}' : rest4 -> pure (JObj (reverse ((k, v) : acc)), rest4)
          _ -> Left "expected ',' or '}' in an object"
      _ -> Left "expected ':' after an object key"
  _ -> Left "expected an object key or '}'"

pArray :: String -> [JValue] -> Either String (JValue, String)
pArray input acc = case input of
  ']' : rest -> pure (JArr (reverse acc), rest)
  _ -> do
    (v, rest1) <- pValue input
    case ws rest1 of
      ',' : rest2 -> pArray (ws rest2) (v : acc)
      ']' : rest2 -> pure (JArr (reverse (v : acc)), rest2)
      _ -> Left "expected ',' or ']' in an array"

pString :: String -> String -> Either String (String, String)
pString input acc = case input of
  [] -> Left "unterminated string"
  '"' : rest -> pure (reverse acc, rest)
  '\\' : e : rest -> case e of
    '"' -> pString rest ('"' : acc)
    '\\' -> pString rest ('\\' : acc)
    '/' -> pString rest ('/' : acc)
    'b' -> pString rest ('\b' : acc)
    'f' -> pString rest ('\f' : acc)
    'n' -> pString rest ('\n' : acc)
    'r' -> pString rest ('\r' : acc)
    't' -> pString rest ('\t' : acc)
    'u' -> case splitAt 4 rest of
      (hex, rest')
        | length hex == 4
        , all isHexDigit hex ->
            pString rest' (toEnum (hexValue hex) : acc)
      _ -> Left "bad \\u escape"
    _ -> Left "bad escape in a string"
  c : rest -> pString rest (c : acc)

hexValue :: String -> Int
hexValue = foldl (\acc c -> acc * 16 + digitOf c) 0
  where
    digitOf c
      | isDigit c = fromEnum c - fromEnum '0'
      | c >= 'a' && c <= 'f' = fromEnum c - fromEnum 'a' + 10
      | otherwise = fromEnum c - fromEnum 'A' + 10

pNumber :: String -> Either String (JValue, String)
pNumber input =
  let (sign, rest0) = case input of
        '-' : r -> (-1 :: Integer, r)
        _ -> (1, input)
      (digits, rest1) = span isDigit rest0
   in case digits of
        [] -> Left ("unexpected character in the corpus: " ++ take 1 (show input))
        _ -> case rest1 of
          c : _
            | c == '.' || c == 'e' || c == 'E' ->
                Left
                  "non-integer number in the corpus: the corpus is machine-generated \
                  \from integer data, so this is a structural change"
          _ -> pure (JNum (sign * read digits), rest1)

jLookup :: String -> JValue -> Maybe JValue
jLookup k (JObj kvs) = lookup k kvs
jLookup _ _ = Nothing

pathGet :: [String] -> JValue -> Maybe JValue
pathGet [] v = Just v
pathGet (k : ks) v = jLookup k v >>= pathGet ks

--------------------------------------------------------------------------------
-- The pinned side: vendored values rendered in the corpus's own shapes
--------------------------------------------------------------------------------

byteArr :: ByteString -> JValue
byteArr = JArr . map (JNum . fromIntegral) . BS.unpack

-- | A decoded address in the corpus row's shape. The corpus rows under
-- comparison exercise enterprise addresses with payment-key
-- credentials; the other constructor spellings follow the corpus's
-- @form@ / @paymentCredential@ vocabulary and would surface any
-- vocabulary change as drift.
addrJson :: Address -> JValue
addrJson a =
  JObj
    [ ("bytes", byteArr (addressBytes a))
    ,
      ( "form"
      , JStr $ case addressForm a of
          EnterpriseForm -> "enterprise"
          BaseForm -> "base"
      )
    , ("network", JNum (fromIntegral (addressNetwork a)))
    ,
      ( "paymentCredential"
      , JStr $ case addressPaymentCredential a of
          PaymentKey -> "paymentKey"
          ScriptCredential -> "script"
      )
    , ("paymentHash", byteArr (addressPaymentHash a))
    ,
      ( "stakeCredential"
      , case addressStakeCredential a of
          Nothing -> JNull
          Just c -> JStr $ case c of
            PaymentKey -> "paymentKey"
            ScriptCredential -> "script"
      )
    , ("stakeHash", byteArr (addressStakeHash a))
    ]

-- | @NoDestination@ does not occur in the pinned v0.2.0 rows (WD01's
-- destination is @some@); it is rendered @null@ only so this function
-- is total.
destJson :: PaymentDestination -> JValue
destJson (SomeDestination a) = addrJson a
destJson NoDestination = JNull

fixtureJson :: NamingDatum -> JValue
fixtureJson d =
  JObj
    [ ("controlAddress", addrJson (controlAddress d))
    , ("nextControlCommitment", JObj [("digest", byteArr (nextControlCommitment d))])
    , ("paymentDestination", destJson (paymentDestination d))
    , ( "retirementQuorum"
      , JObj
          [ ("members", JArr (map byteArr (quorumMembers (retirementQuorum d))))
          , ("threshold", JNum (quorumThreshold (retirementQuorum d)))
          ]
      )
    ]

datumShapeJson :: DatumShape -> JValue
datumShapeJson s =
  JObj
    [ ("arity", JNum (fromIntegral (shapeArity s)))
    , ("innerIndex", JNum (fromIntegral (shapeInnerIndex s)))
    , ("outerIndex", JNum (fromIntegral (shapeOuterIndex s)))
    ]

wireDataJson :: WireData -> JValue
wireDataJson = \case
  Constr i fs ->
    JObj
      [ ( "constr"
        , JObj
            [ ("index", JNum (fromIntegral i))
            , ("fields", JArr (map wireDataJson fs))
            ]
        )
      ]
  WBytes b -> JObj [("bytes", byteArr b)]
  WInt n -> JObj [("integer", JNum n)]
  WList fs -> JObj [("list", JArr (map wireDataJson fs))]

proposalJson :: InsertProposal -> JValue
proposalJson p =
  JObj
    [ ("applicationPolicy", JNum (applicationPolicy p))
    , ("initial", initialJson (initial p))
    , ("key", JNum (key p))
    , ("refundAddress", JNum (refundAddress p))
    , ("registry", JNum (registry p))
    , ("scope", JArr (map JNum (scope p)))
    ]

initialJson :: InitialOutput -> JValue
initialJson o =
  JObj
    [ ("datum", JNum (initialDatum o))
    , ("destination", JNum (initialDestination o))
    , ("quantity", JNum (initialQuantity o))
    , ("representative", repJson (initialRepresentative o))
    , ("value", JNum (initialValue o))
    ]

repJson :: Representative -> JValue
repJson r =
  JObj
    [ ("assetScope", JNum (representativeAssetScope r))
    , ("key", JNum (representativeKey r))
    , ("policy", JNum (representativePolicy r))
    , ("registry", JNum (representativeRegistry r))
    ]

requestShapeJson :: InsertRequestShape -> JValue
requestShapeJson s =
  JObj
    [ ("commitmentArity", JNum (fromIntegral (commitmentArity s)))
    , ("commitmentIndex", JNum (fromIntegral (commitmentIndex s)))
    , ("proposalArity", JNum (fromIntegral (proposalArity s)))
    , ("proposalIndex", JNum (fromIntegral (proposalIndex s)))
    ]

comparisonJson :: RefundComparison -> JValue
comparisonJson = \case
  RefundAccepted -> JObj [("accepted", JBool True)]
  RefundRefused r ->
    JObj [("accepted", JBool False), ("reason", JStr (refundReasonText r))]

--------------------------------------------------------------------------------
-- The comparison: every pinned value against its corresponding row field
--------------------------------------------------------------------------------

data Pair = Pair
  { pairVector :: String
  -- ^ the pinned vector's corpus id
  , pairField :: String
  -- ^ the corresponding field of the corpus row, dotted
  , pairVendored :: JValue
  -- ^ the vendored value, rendered in the corpus's own shape
  }

pair :: String -> String -> JValue -> Pair
pair v f val = Pair{pairVector = v, pairField = f, pairVendored = val}

-- | Every value the vendored module pins, against the corpus row field
-- that corresponds to it. @WR01@'s redirected proposal has no corpus
-- row field of its own (the row records the redirect as
-- @redirectedBytes@ plus @presentedRefundAddress@), so it is not
-- listed: the redirect is still covered through both of those.
vendoredPairs :: [Pair]
vendoredPairs =
  [ pair wd01Id "expectedBytes" (byteArr wd01ExpectedBytes)
  , pair wd01Id "malformedBytes" (byteArr wd01MalformedBytes)
  , pair wd01Id "fixture" (fixtureJson wd01Fixture)
  , pair wd01Id "shape" (datumShapeJson wd01Shape)
  , pair wd02Id "attachment.datumHash" (attachmentHash wd02Attachment)
  , pair wd03Id "encoded" (wireDataJson wd03Encoded)
  , pair wr01Id "expectedBytes" (byteArr wr01ExpectedBytes)
  , pair wr01Id "malformedBytes" (byteArr wr01MalformedBytes)
  , pair wr01Id "redirectedBytes" (byteArr wr01RedirectedBytes)
  , pair wr01Id "proposal" (proposalJson wr01StoredProposal)
  , pair wr01Id "shape" (requestShapeJson wr01Shape)
  , pair wr01Id "comparisonResult" (comparisonJson wr01ComparisonResult)
  , pair wr01Id "storedRefundAddress" (JNum wr01StoredRefundAddress)
  , pair wr01Id "presentedRefundAddress" (JNum wr01PresentedRefundAddress)
  ]

attachmentHash :: DatumAttachment -> JValue
attachmentHash (AttachedDatumHash h) = byteArr h
attachmentHash (InlineDatum _) =
  error
    "Vectors.wd02Attachment changed shape: WD02 is pinned as a datum hash"

pairsFor :: String -> [Pair]
pairsFor v = filter ((== v) . pairVector) vendoredPairs

-- | The byte-shaped arrays, rendered for hex diffs. Byte arrays are
-- how the contract's bytes travel in the corpus, so they get
-- byte-level divergence messages (offset plus both values) rather
-- than element indexes.
byteShape :: JValue -> Maybe [Word8]
byteShape (JArr xs) = traverse asByte xs
  where
    asByte (JNum n)
      | n >= 0, n <= 255 = Just (fromIntegral n)
    asByte _ = Nothing
byteShape _ = Nothing

compareJ :: String -> JValue -> JValue -> [String]
compareJ _ v l | v == l = []
compareJ _path v l
  | Just vs <- byteShape v
  , Just ls <- byteShape l =
      [ "  vendored (" ++ show (length vs) ++ " bytes): " ++ hexBytes vs
      , "  live      (" ++ show (length ls) ++ " bytes): " ++ hexBytes ls
      ]
        ++ [ "  length differs: vendored " ++ show (length vs)
               ++ ", live " ++ show (length ls)
           | length vs /= length ls
           ]
        ++ case [ (i, a, b)
                | (i, (a, b)) <- zip [0 :: Int ..] (zip vs ls)
                , a /= b
                ] of
          ((i, a, b) : _) ->
            [ "  first difference at byte " ++ show i
                ++ ": vendored " ++ hexByte a ++ ", live " ++ hexByte b
            ]
          [] -> []
compareJ path (JObj vs) (JObj ls) =
  map
    (\k -> "  " ++ path ++ ": key " ++ show k ++ " missing from the live row")
    missingLive
    ++ map
      (\k -> "  " ++ path ++ ": key " ++ show k ++ " not present in the vendored value")
      extraLive
    ++ concat
      [compareJ (path ++ "." ++ k) (get k vs) (get k ls) | k <- common]
  where
    vkeys = map fst vs
    lkeys = map fst ls
    missingLive = [k | k <- vkeys, k `notElem` lkeys]
    extraLive = [k | k <- lkeys, k `notElem` vkeys]
    common = [k | k <- vkeys, k `elem` lkeys]
    get k kvs = case lookup k kvs of
      Just x -> x
      Nothing -> JNull -- unreachable: k is common to both sides
compareJ path (JArr vs) (JArr ls)
  | length vs == length ls =
      concat
        [ compareJ (path ++ "[" ++ show i ++ "]") a b
        | (i, (a, b)) <- zip [0 :: Int ..] (zip vs ls)
        ]
compareJ path v l =
  ["  " ++ path ++ ": vendored " ++ renderJson v ++ ", live " ++ renderJson l]

renderJson :: JValue -> String
renderJson JNull = "null"
renderJson (JBool b) = if b then "true" else "false"
renderJson (JNum n) = show n
renderJson (JStr s) = show s
renderJson (JArr xs) = "[" ++ intercalate "," (map renderJson xs) ++ "]"
renderJson (JObj kvs) =
  "{" ++ intercalate "," [show k ++ ":" ++ renderJson v | (k, v) <- kvs] ++ "}"

hexDigits :: String
hexDigits = "0123456789abcdef"

hexByte :: Word8 -> String
hexByte w =
  [hexDigits !! fromIntegral (w `div` 16), hexDigits !! fromIntegral (w `mod` 16)]

hexBytes :: [Word8] -> String
hexBytes = concatMap hexByte

--------------------------------------------------------------------------------
-- The vendored module's provenance header: what the pin says it is
--------------------------------------------------------------------------------

-- | The @--   * release: …@ line of the provenance header, so the
-- check states the pin from the vendored module's own testimony
-- rather than a copy that could drift from it.
extractRelease :: String -> Either String String
extractRelease src = case mapMaybe strip (lines src) of
  [r] -> Right (asciiOnly r)
  [] ->
    Left
      "the vendored module does not state its release \
      \(expected a '--   * release: ' line in the provenance header)"
  rs -> Left ("multiple release lines in the vendored module: " ++ show rs)
  where
    strip l = stripPrefix "--   * release: " l

-- | The release asset sha256 recorded in the provenance header (the
-- @\@<64 hex chars>\@@ value; the release commit is 40 chars and does
-- not match).
extractSha256 :: String -> Either String String
extractSha256 src = case firstSha256 src of
  Just h -> Right h
  Nothing ->
    Left
      "the vendored module does not record its release asset sha256 \
      \(expected an '@<64 hex characters>@' value in the provenance header)"

firstSha256 :: String -> Maybe String
firstSha256 [] = Nothing
firstSha256 (c : rest)
  | c == '@'
  , (h, more) <- splitAt 64 rest
  , length h == 64
  , all isHexDigit h
  , '@' : _ <- more =
      Just h
  | otherwise = firstSha256 rest

-- | Keep the report printable under any locale: the vendored header's
-- em dashes become '-'.
asciiOnly :: String -> String
asciiOnly = map (\c -> if c <= '\x7f' then c else '-')

--------------------------------------------------------------------------------
-- The corpus rows
--------------------------------------------------------------------------------

wireRows :: JValue -> Either String [(String, JValue)]
wireRows corpus = do
  wire <- note "the live corpus has no .wire array" (jLookup "wire" corpus)
  case wire of
    JArr rs -> do
      named <- mapM rowId rs
      let ids = map fst named
          dups = [g | g <- group (sort ids), length g > 1]
      case dups of
        [] -> Right named
        _ ->
          Left
            ( "duplicate wire row ids in the live corpus: "
                ++ show (concat dups)
            )
    _ -> Left "the live corpus .wire is not an array"
  where
    rowId r = case jLookup "id" r of
      Just (JStr i) -> Right (i, r)
      Just _ -> Left "a .wire row has a non-string id"
      Nothing -> Left "a .wire row has no id"

note :: e -> Maybe a -> Either e a
note msg = maybe (Left msg) Right

--------------------------------------------------------------------------------
-- Orchestration
--------------------------------------------------------------------------------

data FieldOutcome
  = FieldOk String
  | FieldDiff [String]

pinnedVecIds :: [String]
pinnedVecIds = [wd01Id, wd02Id, wd03Id, wr01Id]

readInput :: FilePath -> IO String
readInput p = do
  ok <- doesFileExist p
  if ok
    then readFile p
    else bail 2 ("input not found: " ++ p)

bail :: Int -> String -> IO a
bail code msg = do
  hPutStrLn stderr ("vector-drift-check: " ++ msg)
  exitWith (ExitFailure code)

main :: IO ()
main = do
  argv <- getArgs
  (vectorsPath, corpusPath) <- case argv of
    [v, c] -> pure (v, c)
    _ -> bail 2 "usage: drift-check <Vectors.hs> <lifecycle-corpus.json>"
  vectorsSrc <- readInput vectorsPath
  pinRelease <- either (bail 2) pure (extractRelease vectorsSrc)
  pinSha <- either (bail 2) pure (extractSha256 vectorsSrc)
  corpusSrc <- readInput corpusPath
  corpus <-
    either
      (bail 2 . ("cannot read the live corpus: " ++))
      pure
      (parseJson corpusSrc)
  rows <- either (bail 2) pure (wireRows corpus)
  let corpusSha = case jLookup "corpusSourceSha256" corpus of
        Just (JStr s) -> s
        _ -> "not stated"
  putStrLn "vector-drift-check"
  putStrLn
    ( "drift-pinned-release: " ++ pinRelease
        ++ " (asset sha256 " ++ pinSha ++ ")"
    )
  putStrLn
    ( "drift-live-corpus: " ++ corpusPath
        ++ " (corpusSourceSha256 " ++ corpusSha ++ ")"
    )
  let fieldOutcome p row = case pathGet (dotPath (pairField p)) row of
        Nothing ->
          FieldDiff
            [ "  " ++ pairField p ++ ": the live row has no field "
                ++ show (pairField p)
            ]
        Just live -> case compareJ (pairField p) (pairVendored p) live of
          [] -> FieldOk (identSummary (pairVendored p))
          ds -> FieldDiff ds
      identSummary v = case byteShape v of
        Just bs -> "identical (" ++ show (length bs) ++ " bytes)"
        Nothing -> "identical"
      perVector =
        [ ( v
          , fmap
              (\row -> [(pairField p, fieldOutcome p row) | p <- pairsFor v])
              (lookup v rows)
          )
        | v <- pinnedVecIds
        ]
      totalFields = sum [length fs | (_, Just fs) <- perVector]
      okFields = length [() | (_, Just fs) <- perVector, (_, FieldOk _) <- fs]
  forM_ perVector $ \(v, mfs) -> case mfs of
    Nothing -> do
      putStrLn ("DIVERGENT " ++ v)
      putStrLn
        "  the live corpus has no wire row with this id - the pinned vector is gone"
    Just fs -> forM_ fs $ \(f, o) -> case o of
      FieldOk s -> putStrLn ("compared " ++ v ++ " " ++ f ++ ": " ++ s)
      FieldDiff ds -> do
        putStrLn ("DIVERGENT " ++ v ++ " " ++ f)
        mapM_ putStrLn ds
  let missingRows = [v | (v, Nothing) <- perVector]
      extraRows = [i | (i, _) <- rows, i `notElem` pinnedVecIds]
  unless (null extraRows) $ do
    putStrLn
      "extra-row notice: the live corpus ships wire vectors the pinned release does not cover:"
    mapM_ (\i -> putStrLn ("  " ++ i)) extraRows
  if null missingRows && okFields == totalFields && null extraRows
    then do
      putStrLn
        ( "no drift: " ++ show okFields ++ " comparisons identical across "
            ++ show (length pinnedVecIds)
            ++ " pinned vectors - the vendored v0.2.0 copy and the live "
            ++ "corpus are in agreement"
        )
      exitSuccess
    else do
      putStrLn
        ( "drift: the live corpus has moved relative to the vendored v0.2.0 pin "
            ++ "(" ++ show (totalFields - okFields) ++ " divergent field(s), "
            ++ show (length missingRows) ++ " missing row(s), "
            ++ show (length extraRows) ++ " extra row(s)); the pin stays - "
            ++ "a human decides whether to adopt the new contract"
        )
      exitFailure

dotPath :: String -> [String]
dotPath s = case break (== '.') s of
  (a, '.' : rest) -> a : dotPath rest
  (a, _) -> [a]
