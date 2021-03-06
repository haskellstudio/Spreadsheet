{-# LANGUAGE GADTs #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE TypeOperators #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE UndecidableInstances #-}
{-# LANGUAGE ViewPatterns #-}
{-# LANGUAGE DeriveFunctor #-}
{-# LANGUAGE NoMonomorphismRestriction #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE InstanceSigs #-}

module Sheet (isCirc, recalc, (Sheet.//), showSheet, toTuple, lastRef, lastCell, readSheet, Sheet(..), (Sheet.!), shift) where

import Control.Monad.ST
import Data.Array.ST

import Data.Array 
import Data.Maybe
import Text.Read (readMaybe)
import Data.List hiding (foldr)
import Data.List.Split
import Data.Foldable as F hiding (concat)
import Control.Monad
import Control.Monad.Identity
import Control.Comonad
--import Control.ComonadApply
import Text.Printf
import Data.Either.Utils (fromRight)
import Cat
import Ref
import Value
import Text.PrettyPrint hiding ((<>))
import Control.Lens hiding (indices)

-- This file is experimenting with different versions of spreadsheets
-- We need the type to be Sheet (Sheet c -> c) so that cfix and loeb work

-- Now, the a in Sheet a needs to be (Sheet c -> c)
-- But the parser parses to CellFn which is Sheet Fix Cell -> Fix Cell
-- So the c is Fix Cell and we have a sheet of CellFn's - ie. Sheet CellFn

-- | A spreadsheet - just an array of references with content, a name and a focus (so that we can have a Comonad)
data Sheet a = Sheet { name::String, focus::Ref, cells::Array Ref a} deriving (Eq)

-- | Just apply the function to the array
instance Functor Sheet where
    fmap f (Sheet n r xss) =  Sheet n r $ fmap f xss

instance Comonad Sheet where
	extract (Sheet n ix css) = css Data.Array.! ix
	duplicate (Sheet n ix css) = Sheet n ix $ listArray (bounds css) $ fmap (\jx-> Sheet n jx css) $ indices css

--instance ComonadApply (Array Ref) where
--    (a1) <@> (a2) = array (lower, upper) $ map (\ix -> (ix, (a1 Data.Array.! ix) (a2 Data.Array.! ix))) newIndices
--                    where
--                        newIndices = intersect (indices a1) $ indices a2
--                        lower = max (fst $ bounds a1) (fst $ bounds a2)
--                        upper = min (snd $ bounds a1) (snd $ bounds a2)

instance ComonadApply Sheet where
    (Sheet n1 f1 fs) <@> (Sheet n2 f2 as) = Sheet n1 f1 $ apply fs as
        where
            apply (a1)(a2) = array (lower, upper) $ map (\ix -> (ix, (a1 Data.Array.! ix) (a2 Data.Array.! ix))) newIndices
                    where
                        newIndices = intersect (indices a1) $ indices a2
                        lower = max (fst $ bounds a1) (fst $ bounds a2)
                        upper = min (snd $ bounds a1) (snd $ bounds a2)

-- | Evaluate and print the cellFns here is the LOEB!
recalc :: (Eval a Id) => Sheet (Sheet (Fix a) -> Fix a) -> Sheet String
recalc fs = fmap (show.runId.(cata evalAlg)) $ loeb fs


-- Returns the parsed input string (ie. a CellFn) applied to the sheet of True/Falses
-- which show the cells that depend on the ref
-- The parsed CellFn just just cfor's all the bools together
-- f = input string parsed using refExpr
-- ss = parseRefsSheet of the Sheet String with the investigated cell replaced by bval True
-- ie. ss = (parseRefsSheet ss) // [(ref, bval True)]
isCirc :: (Eval a Id) =>(Sheet (Fix a) -> Fix a) -> Sheet (Sheet (Fix a) -> Fix a) -> Bool
isCirc f ss = (runId $ eval $ f $ loeb ss) == (B True)


-- Shifts the focus by adding r1 to it
shift :: Ref -> Sheet a -> Sheet a
shift r1 ss@(Sheet n r2 ass) = Sheet n (refAdd (lastRef ss) r1 r2) ass

instance (Show e) => Show (Sheet e) where
    show ss = printf $ concat $ intersperse "\n" $  [name ss, show $ focus ss, show $ lastRef ss] ++ (elems $ fmap show $ cells ss)

-- A show for String sheets - so that we don't get strings wrapped with "s.
showSheet :: Sheet String -> String
showSheet ss = printf $ concat $ intersperse "\n" $  [name ss, show $ focus ss, show $ lastRef ss] ++ (elems $ cells ss)

-- Just folds on the Array of cells
instance Foldable Sheet where
    foldr :: forall a b. (a -> b-> b) -> b -> Sheet a -> b
    foldr f z s = F.foldr f z $ cells s
 
(//) :: Sheet a -> [(Ref, a)] -> Sheet a
(//) (Sheet n f as) rs = Sheet n f $ as Data.Array.// rs

(!)::Sheet a ->Ref-> a
(!) s r =  (cells s)Data.Array.!r
 
lastCell :: Sheet a -> (Int, Int) 
lastCell s = toCoords $ snd $ bounds $ cells s
 
lastRef :: Sheet a -> Ref 
lastRef s = fromCoords $ lastCell s

-- Turns a [string,string] into a (string, String)
-- This is a horrible function
toTuple :: [String] -> (String,String)
toTuple [] = ("", "")
toTuple (x:[]) = (x, "")
toTuple (x:y:ys) = (x, y)

readLine :: (String, String) -> (Ref, String)
readLine (refString, contents) = (readRef refString, contents)

zeroSheet :: Sheet String
zeroSheet = Sheet "Empty" (fromCoords (0,0)) emptyArray

emptyArray = listArray (fromCoords (0,0), fromCoords (0,0)) []

-- | Reads a file to a (Sheet String)
--   So the strings represent the user input in the cells
--   This is pretty poor function - we probably should have a Maybe Sheet?
readSheet :: String -> IO (Sheet String, Sheet Format)
readSheet fileName = do
    ls <- liftM lines $ readFile fileName
    let name :: String
        name = head ls
        focus = readRef $ head $ tail ls       
        bound = readRef $ head $ tail  $ tail ls
        -- The full extent of my knowledge of Lens is here.
        -- This turns the line into a tuple and then applies readRef to the first item
        cells = fmap ((_1 %~ readRef) . toTuple . (take 2) . (splitOn ",")) $ drop 3 ls

        formats = zip (fmap (readRef . head . (splitOn ",")) $ drop 3 ls) (fmap (defaultFormat . (splitOn ",")) $ drop 3 ls)
    return $ (Sheet name focus $ array (fromCoords (1,1), bound) cells, Sheet name focus $ array (fromCoords (1,1), bound) formats)


defaultFormat :: [String] -> Format
defaultFormat ss = maybe (FN 2) id $ ff ss
    where
        ff :: [String] -> Maybe Format
        ff ss = if ((length ss) <3) then Nothing else (if ss!!2== ("-1") then (Just YMD) else (fmap (FN) (readMaybe $ ss!!2)))
                
        


