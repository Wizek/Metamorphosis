{-# LANGUAGE FunctionalDependencies #-}
{-# LANGUAGE MultiParamTypeClasses, FlexibleInstances #-}
{-# LANGUAGE QuasiQuotes, TemplateHaskell #-}
module Metamorphosis where

import           Control.Monad
import           Data.Char
import           Data.Function (on)
import           Data.List (sort, nub, group, groupBy)
import           Data.Map (Map)
import qualified Data.Map as Map
import           Data.Maybe
import           Debug.Trace
import           Language.Haskell.TH
import           Language.Haskell.TH.Syntax
import Data.Functor.Identity
import Lens.Micro.TH

type TName = String -- Type name
type CName = String -- Constructor name
type FName = String -- field name


-- | Converts a type (AST) to a list of String (chain)
-- ex: Maybe Int -> ["Maybe", "Int"]
typeToChain :: Type -> [String]
typeToChain (ForallT _ _ typ ) = typeToChain typ
typeToChain (AppT f t) = typeToChain f ++ typeToChain t
typeToChain (SigT t _ ) = typeToChain t
typeToChain (VarT n) = [nameBase n]
typeToChain (ConT t) = [nameBase t]
typeToChain (PromotedT t) = [nameBase t]
typeToChain info = error $ "typeToChain not implemented for :" ++ show info
             
-- | Converts a list of string (chain) to an AST type
-- ex: ["Maybe", "Int"] -> Maybe Int
chainToType :: [String] -> Maybe Type
chainToType [] = Nothing
chainToType [t] | isVar t = Just $ VarT (mkName t)
                | otherwise = Just $ ConT (mkName t)
chainToType (t:ts) =  liftM2 AppT (chainToType [t]) (chainToType ts)
  

-- | Check if a variable name is a variable or a constructor (upper case)
isVar [] = False
isVar (c:cs) = isLower c

sequence =  error "FIX ME"

-- * TH
-- ** Type
-- | Represents the field of a data (within its' contructor)
-- For example, data A = A { x :: Int} will have one field A.A.x [Int]
data FieldDesc = FieldDesc
  { _fdTName :: String -- ^ Type name
  , _fdCName :: String -- ^ Constructor name
  , _fdPos :: Int -- ^ position within the constructor
  , _fdFName :: Maybe String -- ^ Field Name if Recorder
  , _fdBang :: Bang
  , _fdTypes :: [String] -- ^ [] means no field at all (ex Enum)
  , _fdMName :: Maybe String -- ^ Module name . only used to use proper constructor name

  } deriving (Show, Eq, Ord)

makeLenses ''FieldDesc

-- | poor man refinement type
-- Just a way to tell that some functions want or generate sorted list
data GroupedByType = GroupedByType (Maybe String) String [FieldDesc]
data GroupedByCons = GroupedByCons (Maybe String) String [FieldDesc]

-- ** Function
-- | The workhorse of this package. Transform a set of data types to another set of data types
-- The mapping between old fields to new is done by a mapping function.
-- It can be used to copy a class, split it to multiple ones, split to sum type
-- aggregate sum type to product types etc ...
metamorphosis :: (FieldDesc -> [FieldDesc]) -> [Name] -> Q [Dec]
metamorphosis f names = do
  infos <- mapM reify names
  let fields = concatMap collectFields infos
      newFields = concatMap f fields
  return $ map generateType (groupByType newFields)

-- Retrieves the field descriptions of data type (from its Info)
collectFields :: Info -> [FieldDesc]
collectFields (TyConI (DataD cxt tName vars kind cons cxt')) = concatMap go cons where
  go (NormalC cName []) =  [ FieldDesc { _fdTName = nameBase tName
                                     , _fdCName = nameBase cName
                                     , _fdFName = Nothing
                                     , _fdPos = 0
                                     , _fdBang = (Bang NoSourceUnpackedness NoSourceStrictness)
                                     , _fdTypes = []
                                     , _fdMName = nameModule tName
                                     }
                           ]
  go (NormalC cName bangs) =  zipWith (go' cName) bangs [1..]
  go (RecC cName varbangs) =  zipWith (go'' cName) varbangs [1..]
  go (InfixC bang cName bang') = [ go' cName bang 1
                                 , go' cName bang' 2
                                 ]

  go' cName (bang, typ) pos = FieldDesc { _fdTName = nameBase tName
                                    , _fdCName = nameBase cName
                                    , _fdFName = Nothing
                                    , _fdPos  = pos
                                    , _fdBang = bang
                                    , _fdTypes = typeToChain typ
                                    , _fdMName = nameModule tName
                                    }

  go'' cName (fName, bang, typ) pos = (go' cName (bang, typ) pos) {_fdFName = Just (nameBase fName)}
collectFields info = error $ "collectFields only works with type declaration." ++ show ( ppr info )

-- | Opposite of {collectFields} : generate a data type from a (grouped) list  of FieldDesc.
-- Can generates sum and record types as well as parametric types.
-- example [(A.A.a, [Int]), (A.A.b, [f, Int]), (A.B.name, String)  ] will generateType
-- data A f = A { a :: Int, b :: f Int } | B { name :: String}
generateType :: GroupedByType -> Dec
generateType group@(GroupedByType mName tName fields) = let
  cons = groupByCons group
  vars = nub $ sort (concatMap getVars fields) 
  in DataD [] (mkName tName) vars Nothing (map generateCons cons) []

-- | Generates the constructor clause of type given a (grouped) list of FieldDesc.
generateCons :: GroupedByCons -> Con
generateCons (GroupedByCons mName cName fields) = let
  sorted = sort fields -- sort by position
  cname = mkName (capitalize cName)
  -- check all fields have a name or not
  in case traverse toVarBangType fields of
    Nothing -> NormalC cname (mapMaybe toBangType fields)
    Just [] -> NormalC cname []
    Just varbangs -> RecC (mkName cName) (varbangs)

-- | Convert a {FieldDesc}  to a TH {BangType} : a field without name  in a constructor declaration
-- ex : !Int in data A =  A !Int 
toBangType :: FieldDesc -> Maybe BangType
toBangType field = fmap (\t -> (_fdBang field, t)) (toType field)

-- | Convert a {FieldDesc}  to a TH {VarBangType} : a field a name  in a record declaration
-- ex : x :: Int in data R =  R { x :: Int }
toVarBangType :: FieldDesc -> Maybe VarBangType
toVarBangType field = case _fdFName field of
  Nothing -> Nothing
  Just name -> fmap (\t -> (mkName name, _fdBang field, t)) (toType field)

-- | Get the Type of a FieldDesc
toType :: FieldDesc -> Maybe Type
toType field = chainToType (_fdTypes field)

-- | Extract parametric variables from a field
-- example "f Int" -> ["f"]
getVars :: FieldDesc -> [TyVarBndr]
getVars field = let
  vars = filter (isVar) (_fdTypes field)
  in map (PlainTV . mkName) vars
   
-- | Groups a list of FieldDesc by Type.
groupByType :: [FieldDesc] -> [GroupedByType]
groupByType fields =  let
  sorted = sort fields
  groups = groupBy ((==) `on` _fdTName) fields
  in [GroupedByType (_fdMName master) (_fdTName master) group | group <- groups, let master = head group ]

-- | Groups a list of FieldDesc by Constructor.
-- All the FieldDesc should belongs to the same Type. Enforced by GroupedByType
groupByCons :: GroupedByType -> [GroupedByCons]
groupByCons  (GroupedByType _ _ fields)= let
  sorted = sort fields
  groups = groupBy ((==) `on` _fdCName) fields
  in [GroupedByCons (_fdMName master) (_fdCName master) group | group <- groups, let master = head group ]


printDecs :: String ->  Q [Dec] ->  Q [Dec]
printDecs name qDecs = do
  decs <- qDecs
  let str = show decs
  sq <- [|str|]
  return [ ValD (VarP (mkName name)) (NormalB sq) []]
  


-- * Helper

capitalize [] = []
capitalize (c:cs) = toUpper c : cs

uncapitalize [] = []
uncapitalize (c:cs) = toLower c : cs

-- ** FieldDesc Combinator
_fdName :: String -> FieldDesc -> [FieldDesc]
_fdName name fd = [fd {_fdTName = name, _fdCName = name }]


-- * convert
-- | Generates an extract function from a set of types to a set of types
-- In order to be able to "traverse" the generated function return a tuple of applicative
-- example XYZ -> (m1 XY, m2 Z)
-- will generate extract (X x y z) = (XY <$> extractF  x <*> extractF y, Z <$> extractF z)
-- extractF is used to convert between different type of applicative.
-- Example, if we have `data XYZ = XYZ Int Int (Maybe Int); data XY = XY Int Int ` but `data Z = Z Int`
-- xyzToXy`y would have in practive the type `XYZ -> (Identity XY, Maybe Z)`
generateExtract :: (FieldDesc -> [FieldDesc]) -> [Name] -> [Name] -> String ->  DecsQ
generateExtract f as bs fname = do
  aInfos <- mapM reify as
  bInfos <- mapM reify bs
  
  let aFields = concatMap collectFields aInfos
      bFields = concatMap collectFields bInfos
      bnames = map nameBase bs

      clauses = buildExtractClauses f aFields bnames bFields
      result =  generateExtract' f aFields bnames bFields fname
  return result

generateExtract' f aFields bnames bFields fname = let
      clauses = buildExtractClauses f aFields bnames bFields
      in [ FunD (mkName fname) clauses ]

buildExtractClauses :: (FieldDesc -> [FieldDesc]) -> [FieldDesc] -> [String] -> [FieldDesc] -> [Clause]
buildExtractClauses f fields targets bfields = let
  -- | Transform a field and check if matches the required targets
  trans :: FieldDesc -> Maybe [FieldDesc]
  trans field = let newFields = f field
                in if all ((`elem` targets) . _fdTName) newFields
                      then Just newFields
                      else Nothing
  groups = groupByType fields
  -- generates all constructor combinations
  go :: [GroupedByCons] -> [GroupedByType] -> [Clause]
  go [] [] = error $ "Can't generate extract function for " ++ show fields
  go typeCons [] = maybeToList $ buildExtractClause f targets typeCons (groupByType bfields)
  go typeCons (group:groups) = do -- []
    cons <- groupByCons group
    go (cons:typeCons) groups 
  in go [] groups 

buildExtractClause :: (FieldDesc -> [FieldDesc]) -> [String] -> [GroupedByCons] -> [GroupedByType] -> Maybe Clause
buildExtractClause f names groups btypes =  let
  pats = [ConP (mkName cname) (fieldPats fields)  | (GroupedByCons mname cname fields) <- groups]
  fieldPats fields = map fieldPat fields
  fieldPat field = case f field of
    [] -> WildP
    _ -> VarP (_fdPatName field)

  fields = concat [ fields | (GroupedByCons _ _ fields) <- groups ]
  fieldAssoc = Map.fromList [ (_fdPatName new, _fdPatName field)
                            | (news, field) <- zip (map f fields) fields
                            , new <- news 
                            ]
  body = TupE (map (consBody fieldAssoc) btypes)
  -- in traceShowId $ Just $ Clause (map ParensP pats) (NormalB body) []
  result = Clause (map ParensP pats) (NormalB body) []
  in (Just result)

-- | Recalculates the position of a field relative to its constructor
-- example [2,5,10] -> [1,2,3]
recomputeFDPositions :: [FieldDesc] -> [FieldDesc]
recomputeFDPositions fields = let
  groups = map (map go . groupByCons) (groupByType fields)
  go group@(GroupedByCons _ _ fields) = zipWith (\fd i -> fd { _fdPos = i }) fields [1..]
  in concatMap (concat) groups

_fdPatName :: FieldDesc -> Name
_fdPatName field = mkName $ "_" ++ _fdCName field
                         ++ fromMaybe ("v" ++ show (_fdPos field))
                                      (_fdFName field)

consBody :: Map Name Name -> GroupedByType -> Exp
consBody varMap (GroupedByType mname typ fields) = let
  vars = map findVar fields 
  findVar fd = case Map.lookup (_fdPatName fd) varMap of
    Nothing -> error $ "can't extract field " ++ show fd
    Just vname -> VarE vname
  result =  foldl (\x y -> UInfixE x (VarE $ mkName "<*>" ) y)
           (AppE (VarE (mkName "pure"))
                 (ConE (mkName $ maybe "" (++ "." ) mname ++ typ))
           )
           (map (AppE (VarE $ mkName "extractF")) vars)
  in traceShow (varMap, ppr result) result
 -- pat = patTuble 
  -- A x
  -- A y
  -- A s -- not used
  -- B z
  -- B Nothing

  -- A x, B z -> AB (Just x) Nothing (Just z)
  -- A x, B Nothing -> AB (Just x) Nothing Nothing
  -- A s , ... -> not used
  -- A y, B z -> AB Nothing (Just y) (Just z)
  -- A y, B Nothing -> AB Nothing (Just y) Nothing
  
  
-- data Action = GSetter | GGetter deriving (Show, Read, Eq, Ord)
-- the target names are string, as generated data types are not available
-- to TH yet
metamorphosis' :: (FieldDesc -> [FieldDesc]) -> [Name] ->[String] -> Q [Dec]
metamorphosis' f anames bnames = do
  typeDecs <- metamorphosis f anames

  aInfos <- mapM reify anames
  let aFields = concatMap collectFields  aInfos
      bFields = concatMap f aFields

      convertName = extractName (map nameBase anames) bnames
      convertDecs = generateExtract' f aFields bnames bFields convertName

  return (typeDecs ++ convertDecs)


-- generate the name of the extract function
extractName :: [String] -> [String] -> String
extractName ins outs = aggregateNames ins ++ "To" ++ capitalize (aggregateNames outs) ++ "A"


aggregateNames :: [String] -> String
aggregateNames names = uncapitalize $ concatMap (capitalize) names

  


  
 
-- | like inject but whereas inject is losless, tranfer isn't.
-- There is no way to extract the inject result.

class Transfer a e where
  transfer :: a -> e -> a
  recover :: a -> Maybe e
 
class ExtractF a f b where
  extractF ::a -> f b

instance Applicative f => ExtractF a f a where
  extractF  = pure
instance Applicative f => ExtractF (f a) f a where
  extractF  = id
instance Applicative f => ExtractF a Identity (f a) where
  extractF = pure . pure
instance ExtractF () Maybe a where
  extractF () = Nothing
instance Monoid a => ExtractF () Identity a where
  extractF () = Identity mempty

instance (Applicative f, ExtractF a f a', ExtractF b f b') => ExtractF (a, b) f (a',b') where
  extractF (a,b) = (,) <$> extractF a <*> extractF b
instance (Applicative f, ExtractF a f a', ExtractF b f b', ExtractF c f c') => ExtractF (a, b, c) f (a',b', c') where
  extractF (a,b,c) = (,,) <$> extractF a <*> extractF b <*> extractF c
-- * rseq
 
-- R f => f R  Identity


-- * rmap
-- R -> (forall x . x -> a) -> [a]


  
