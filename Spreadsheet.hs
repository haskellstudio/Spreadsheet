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

--module Spreadsheet (e1, e2, e3, v1, v2, v3, e, val, vat, sheet2, sheet3, sheet4, sheet5, wfixTest
--                    , wfixTest2, wfixTest3, wfixTest4, wfixTest5, r4, cr4, v4, setBlur, UI.setFocus, setup, getCell, renderCell, ee) where

import Data.Array hiding ((!))
import Data.Maybe
import Data.Foldable as F hiding (concatMap)
import Data.List.Split hiding (split)
import Control.Monad.Identity
import Control.Comonad hiding ((<@))
import Data.Char
import Text.ParserCombinators.Parsec as P hiding (string)
import Text.Read (readMaybe)
import Data.IORef
import Data.Time.Calendar

import qualified Control.Monad.State as S
import qualified Graphics.UI.Threepenny as UI
import Graphics.UI.Threepenny.Core as C hiding (split)

import Control.Concurrent.STM.TVar
import Control.Concurrent.STM

import Cat
import Value
import Refs
import Expr
import Sheet
import Cell
import Parser
import SpreadsheetTest


-- TO DO

-- 1. Add checking of circular references when text is entered
-- 2. Add vlookup, hlookup and index functions

main :: IO ()
main = do   
    let fileName = "TestSheet.ss"
    (sheet, formatSheet) <- readSheet fileName
    rSheets <- newIORef (sheet, formatSheet) 
    startGUI defaultConfig $ setup rSheets

setup :: IORef (Sheet String, Sheet Format)-> Window -> UI ()
setup rSheets window = void $ do   
    (sheet, formatSheet)  <- liftIO $ readIORef rSheets
    let (ncols, nrows) = lastCell sheet
    
    set title "Spreadsheet" $ return window     
    -- cells with no behaviour, just labelling
    cellss <- sequence $ map (\row-> sequence $ map (\col-> 
                                                        simpleCell rSheets $ fromCoords (col, row) 
                                                    ) [1..ncols]
                             ) [1..nrows]

    -- This behaviour has the value of each cell
    bInputss <- uiApply cellss (\(cell,ref) -> do  
                                                let e = fmap (\a-> (a, ref)) $ UI.valueChange cell
                                                stepper ("", fromCoords (1,1)) e
                               )

    -- These behaviours have the value cells on blurring
    -- If we set cells to blur on move these should be triggered?
    -- We need the ref as well, otherwise we don't know where in the Sheet to save the value
    let blurVals :: [Event (String, Ref)]
        blurVals = concatMap (\(cs, bInputs) -> 
                                        fmap (\(cell, bInput) -> bInput <@ UI.blur cell) $ zip cs bInputs 
                              ) $ zip cellss bInputss

    -- So, this behaviour has the value of the LATEST blurred cell and it's ref
    -- bBlur :: Behavior (String, Ref)
    bBlur <- stepper ("", fromCoords (1,1)) $ fmap head $ UI.unions blurVals        
        
    -- What to do when the cell is blurred
    --      Work out the new input sheet
    --      Save a new sheet to the IORef
    --      Work out the new output sheet
    --      Write new output to all cells
    onChanges bBlur (\(cstr, ref) -> do
                        let (str, fmt) = split cstr
                        liftIO $ updateSheet (str, fmt, ref) rSheets
                        (newInput, newFormat) <- liftIO $ readIORef rSheets
                        let output = recalcSheet $ parseSheet newInput
                        uiApply cellss (\(cell, ref) -> do return cell # set UI.value (showWithFormat (newFormat!ref) $ output!ref))
                    )
        
    -- After all this we need to get the cells to display the user input when on focus
    finalCells <- uiApply cellss (\(cell, ref) -> addFocusAndMoveBehaviour rSheets ref cell)

    let colnames :: [UI Element]
        colnames = (C.string ""):[C.string $ [chr $ ord 'A' + c - 1]|c<-[1..ncols]]
        rows :: [[UI Element]]
        rows = zipWith (\r rowCells -> (C.string $ show r) : map element rowCells) [1..nrows] cellss

    -- This is an input field for the file name
    nameInput <- UI.input
    let displayNameInput :: UI Element
        displayNameInput = do
            (ss, fs) <- liftIO $ readIORef rSheets
            element nameInput # set UI.value (name ss)

    -- Buttons to save and load files
    saveButton <- UI.button # set UI.text "Save"
    loadButton <- UI.button # set UI.text "Load"
    on UI.click saveButton $ \_ -> do 
                                    fileName <- get UI.value nameInput
                                    (sheet, formatSheet) <- liftIO $ readIORef rSheets
                                    liftIO $ writeFile fileName $ showSheet sheet
    on UI.click loadButton $ \_ -> do 
                                    fileName <- get UI.value nameInput
                                    (sheet, formatSheet) <- liftIO $ readSheet fileName
                                    liftIO $ writeIORef rSheets (sheet, formatSheet)
    -- Add all the elements to the window
    getBody window #+ [ grid [[grid $ colnames:rows]]] #+ [displayNameInput] #+ [element saveButton] #+ [element loadButton]


-- | splits the input string into a string which is the CellFn and a format string
split :: String -> (String, Format)
split s = (head ss, if ((length ss) ==1) then (FN 2) else (read $ ss!!1))
    where
        ss = splitOn "," s
        
   
-- | Apply takes a grid of elements and a function from these elements and the ref of each
--   and it applies the function to each element and returns the new ones
uiApply :: [[Element]] -> ((Element, Ref) -> UI a) -> UI [[a]]
uiApply cellss f = sequence $ map (\(cs, row) -> 
                                    sequence $ map (\(cell, col) -> do  
                                                        f (cell, fromCoords (col, row))
                                                   ) $ zip cs [1..]
                               ) $ zip cellss [1..]

-- | Updates the IORef Sheet with a new user input string
--   This needs to be mended so that it sorts out circular references
updateSheet :: (String, Format, Ref)->IORef (Sheet String, Sheet Format) -> IO ()
updateSheet (str, fmt, ref) rSheet = do
    (oldSheet, oldFormat) <- liftIO $ readIORef rSheet
    let newSheet = Sheet (name oldSheet) (focus oldSheet) $ (cells oldSheet)//[(ref,str)] 
    let newFormat = Sheet (name oldFormat) (focus oldFormat) $ (cells oldFormat)//[(ref,fmt)] 
    liftIO $ writeIORef rSheet (newSheet, newFormat)
        
-- | This just makes a simple cell with an id and a tabindex and no behaviour
simpleCell :: IORef (Sheet String, Sheet Format) -> Ref -> UI Element
simpleCell rSheet ref =  do
    (sheet, formatSheet)  <- liftIO $ readIORef rSheet
    let (ncols, nrows) = lastCell sheet
        (col, row) = toCoords ref
        tabIndex = col * nrows + row
    UI.input # set (attr "tabindex") (show tabIndex) # set UI.id_ (show ref) 

-- | Adds behaviour to a field in the spreadsheet
--   The behaviour added moves when a move key (left, right, up, down, enter) is pressed
--   and puts the user input string back in when the field get focus.
addFocusAndMoveBehaviour :: IORef (Sheet String, Sheet Format) -> Ref -> Element -> UI Element
addFocusAndMoveBehaviour rSheet ref input = do
    -- Set the on focus behaviour so that it saves the user input value on blurring
    (sheet, formatSheet) <- liftIO $ readIORef rSheet
    bUserInput <- stepper ((sheet)!ref) $ UI.valueChange input
    bValue <- stepper ((sheet)!ref) $ bUserInput <@ UI.focus input
    sink UI.value bValue $ return input
    -- Set the move behaviour - move when move key is pressed
    let move :: Ref -> UI ()
        move direction = do
            setBlur input
            next <- getCell $ refAdd (lastRef sheet) ref direction
            UI.setFocus next
            
    on UI.keydown input $ \c ->case c of
                                37 -> do move rLeft
                                38 -> do move rUp
                                39 -> do move rRight
                                40 -> do move rDown
                                13 -> do move rDown
                                _ -> return ()   
    return input

-- | Sets a cell to blurred - copied from UI.setFocus
setBlur :: Element -> UI ()
setBlur = runFunction . ffi "$(%1).blur()"

-- | Gets an element from it's ref
getCell :: Ref -> UI Element
getCell r =  do
    w <- askWindow    
    e <- getElementById w $ show r
    return $ fromJust e


{-******************************************************************************************************

CODE GRAVEYARD

******************************************************************************************************-}

{-
setCell :: Element -> String -> UI ()
setCell e s = do 
    set UI.value s (return e)
    return ()
-}

{-
-- This parses the same but it returns the new sheet
parseToSheet:: Sheet CellFn -> Ref -> String -> Sheet CellFn
parseToSheet sheet ref cellInput = Sheet (name sheet) (focus sheet) newCells
    where
        parsedInput = parse expr "" cellInput
        -- Parse the input to a CellFn and put it in the sheet
        newCells = (cells sheet)//[(ref,either (const $ sval "Parse error") id parsedInput)]
-}


{-
parseToValue:: Sheet CellFn -> Ref -> String-> String
parseToValue sheet ref cellInput = either (const "Parse error") id $ fmap (show . runId . eval) $ fmap ($ newSheet =>> wfix) parsedInput
    where
        parsedInput = parse expr "" cellInput
        -- Parse the input to a CellFn and put it in the sheet
        newCells = (cells sheet)//[(ref,either (const $ sval "Parse error") id parsedInput)]
        -- Make a Sheet with the new cells
        newSheet = Sheet (name sheet) (focus sheet) newCells
-}


{-

-- Sets the behaviour of the cell
renderMove :: IORef (Sheet String) -> Ref -> [[Element]] -> Element -> UI Element
renderMove rSheet refIn eCellss input = do
    sheet <- liftIO $ readIORef rSheet
    let bs = lastRef sheet

    on UI.focus input (\_ -> do
                            ss <- liftIO $ readIORef rSheet
                            (return input) # set UI.value ((ss)!refIn)
                            return ()
                      )

    let recalc :: UI ()
        recalc = do
            val <- get UI.value input
            let newsSheet =  Sheet (name sheet) (focus sheet) $ (cells sheet)//[(refIn,val)] -- sheet of input strings
            liftIO $ writeIORef rSheet newsSheet
            ss <- liftIO $ readIORef rSheet
            --let vs = fmap (show.runId.eval)$ fs =>> wfix -- sheet of value strings
            let vs = recalcSheet $ parseSheet ss -- sheet of Value strings
            sequence $ map (\(eCells, col) -> sequence $ map (\(eCell,row) -> setCell eCell $ (vs)!(fromCoords (row, col))) $ zip eCells [1..]) $ zip eCellss [1..]
            return ()

        -- | Saves input string and parsed CellFn
        -- sets cell value to value string
        -- blurs current cell
        -- finds next cell
        -- sets focus of next cell
        move :: Ref -> UI ()
        move direction = do
            recalc
            setBlur input
            next <- getCell $ refAdd bs refIn direction
            UI.setFocus next
            
    let moveAway :: Element -> Event Int
        moveAway = (\e -> let k = UI.keydown e
                              m = fmap (const (-1)) $ UI.leave e
                          in unionWith (\k m -> k) k m
                                    
                   )
    on moveAway input $ \c ->case c of
                        37 -> do move rLeft
                        38 -> do move rUp
                        39 -> do move rRight
                        40 -> do move rDown
                        13 -> do move rDown
                        _  -> do move rZero
                                
    return input


setupOld :: IORef (Sheet String)-> Window -> UI Element
setupOld rSheet window = do   
    sheet <- liftIO $ readIORef rSheet
    let (ncols, nrows) = lastCell sheet

    set title "Spreadsheet" $ return window     
    -- make the cells and set the in-cell behaviour
    cellFieldss1 <- sequence $ map (\row-> 
            sequence $ map (\col-> do
                let ref = Ref (CAbs col) (RAbs row)
                makeCell rSheet ref -- $ show $ runId $ eval $ (cells (sheet =>> wfix))!ref
            ) [1..ncols]
        ) [1..nrows]

    cellFieldss2 <- sequence $ map (\(cells, row) -> 
            sequence $ map (\(cell, col)-> 
                renderMove rSheet (Ref (CAbs col) (RAbs row)) cellFieldss1 cell
            ) $ zip cells [1..ncols]
        ) $ zip cellFieldss1 [1..nrows]

    let colnames = (C.string ""):[C.string $ [chr $ ord 'A' + c - 1]|c<-[1..ncols]]
        rows = zipWith (\r rowCells -> (C.string $ show r) : map element rowCells) [1..nrows] cellFieldss1

    sheetInput <- UI.span
    let displaySheetInput :: UI Element
        displaySheetInput = do
            ss <- liftIO $ readIORef rSheet
            element sheetInput # set text (show ss)
            return sheetInput

    saveButton <- UI.button # set UI.text "Save"

    displaySheetInput   
    
    on UI.click saveButton $ \_ -> return ()
    getBody window #+ [ grid [[grid $ colnames:rows]]] #+ [displaySheetInput, displaySheetInput, element saveButton]
-}

{-

    --bMove <- stepper 0 $ filterE (\k-> (k==37)||(k==38)||(k==39)||(k==40)||(k==40)) $ UI.keydown input    
    --onChanges bMove ( \_-> recalc )   

    --bUserInput <- stepper ((cells sSheet)!refIn) $ UI.valueChange input
    --let bParsedInput = (parseToValue fSheet refIn) <$> bUserInput
    -- This determines what is shown in a cell
    --bValue <- stepper "" $ fmap head $ UI.unions
        --[ bParsedInput <@ UI.blur input  -- calculate the value when we leave the cell
        --, bUserInput <@ UI.focus input   -- return to user input when go back
        --]
    --sink UI.value bValue $ return input




oldRenderCell :: IORef (Sheet CellFn) -> Ref -> UI Element
oldRenderCell rSheet refIn = do
    let (x,y)= toCoords refIn
    let tabIndex = x * nrows + y

    input  <- UI.input # set (attr "tabindex") (show tabIndex)  # set UI.id_ (show refIn)

    sheet <- liftIO $ readIORef rSheet
    let bs = snd $ bounds $ cells $ sheet

        move :: Ref -> UI ()
        move direction = do
            setBlur input
            next <- getCell $ refAdd bs refIn direction
            UI.setFocus next

    on UI.keydown input $ \c ->case c of
                                37 -> do move rLeft
                                38 -> do move rUp
                                39 -> do move rRight
                                40 -> do move rDown
                                13 -> do move rDown
                                _ -> return ()

    bUserInput <- stepper "" $ UI.valueChange input

    let bParsedInput = (parseToValue sheet refIn) <$> bUserInput
      
    -- Try the on version first...
    on UI.valueChange input $ const $ void $ do  
        val <- get UI.value input
        let newSheet = parseToSheet sheet refIn val
        liftIO $ writeIORef rSheet newSheet
              
    bValue <- stepper "" $ fmap head $ UI.unions
        [ bParsedInput <@ UI.blur input  -- calculate the value when we leave the cell
        , bUserInput <@ UI.focus input   -- return to user input when go back
        ]

    sink UI.value bValue $ return input

-}

