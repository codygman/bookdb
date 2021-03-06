{-# LANGUAGE OverloadedStrings #-}

module Handler.Edit
    ( -- * Display forms
      add
    , edit
    , Handler.Edit.delete

    -- * Save changes
    , commitAdd
    , commitEdit
    , commitDelete
    ) where

import Prelude hiding (null, userError)

import Control.Applicative ((<|>))
import Control.Monad.IO.Class (liftIO)
import Data.Char (chr)
import Data.List (sort)
import Data.Text (Text, null, intercalate, splitOn, unpack, pack)
import Data.Time.Calendar (fromGregorian)
import Data.Time.Clock (UTCTime(..))
import Database.Persist (Entity(..), insert, replace, delete)
import System.FilePath (joinPath, takeExtension, takeFileName)
import Text.Read (readMaybe)
import Database

import Configuration
import Handler.Information
import Handler.Utils
import Routes
import Requests

import qualified Data.ByteString as B
import qualified Data.ByteString.Lazy as BL
import qualified Handler.Templates as T

-- |Display an add form, or an error if in read-only mode
add :: Handler Sitemap
add = onReadWrite add'

-- |Display an edit form, or an error if in read-only mode
edit :: Text -- ^ The ISBN
     -> Handler Sitemap
edit = onReadWrite . withBook edit'

-- |Display a confirm delete page, or an error if in read-only mode
delete :: Text -- ^ The ISBN
       -> Handler Sitemap
delete = onReadWrite . withBook delete'

-- |Commit an add, or display an error if in read-only mode
commitAdd :: Handler Sitemap
commitAdd = onReadWrite commitAdd'

-- |Commit an edit, or display an error if in read-only mode
commitEdit :: Text -- ^ The ISBN
           -> Handler Sitemap
commitEdit = onReadWrite . withBook commitEdit'

-- |Commit a delete, or display an error if in read-only mode
commitDelete :: Text -- ^ The ISBN
             -> Handler Sitemap
commitDelete = onReadWrite . withBook commitDelete'

-------------------------

add' :: Handler Sitemap
add' = do
  suggestion <- suggest
  htmlUrlResponse $ T.addForm suggestion

edit' :: Entity Book -> Handler Sitemap
edit' (Entity _ book) = do
  suggestion <- suggest
  htmlUrlResponse $ T.editForm suggestion book

delete' :: Entity Book -> Handler Sitemap
delete' (Entity _ book) = htmlUrlResponse $ T.confirmDelete book

-------------------------

commitAdd' :: Handler Sitemap
commitAdd' = mutate Nothing

commitEdit' :: Entity Book -> Handler Sitemap
commitEdit' = mutate . Just

commitDelete' :: Entity Book -> Handler Sitemap
commitDelete' (Entity bookId _) = Database.Persist.delete bookId >> information "Book deleted successfully"

-------------------------

-- |Mutate a book, and display a notification when done.
mutate :: Maybe (Entity Book) -- ^ The book to mutate, or Nothing to insert
       -> Handler Sitemap
mutate book = do
  -- do cover upload
  cover      <- uploadCover
  isbn       <- param' "isbn"       ""
  title      <- param' "title"      ""
  subtitle   <- param' "subtitle"   ""
  volume     <- param' "volume"     ""
  fascicle   <- param' "fascicle"   ""
  voltitle   <- param' "voltitle"   ""
  author     <- param' "author"     ""
  translator <- param' "translator" ""
  editor     <- param' "editor"     ""
  sorting    <- param' "sorting"    ""
  read       <- param' "read"       ""
  lastread   <- param' "lastread"   ""
  location   <- param' "location"   ""
  borrower   <- param' "borrower"   ""

  if null isbn || null title || null author || null location
  then userError "Missing required fields"
  else do
    let cover'      = cover <|> (book >>= \(Entity _ b) -> bookCover b)
    let author'     = sortAuthors author
    let translator' = empty translator
    let editor'     = empty editor
    let sorting'    = empty sorting
    let read'       = set read

    case toDate lastread of
      Just lastread' -> do
        let newbook = Book cover' isbn title subtitle volume fascicle voltitle author' translator' editor' sorting' read' lastread' location borrower

        case book of
          Just (Entity bookId _) -> replace bookId newbook >> information "Book updated successfully"
          Nothing -> insert newbook >> information "Book added successfully"

      Nothing -> userError "Invalid date format, expected yyyy-mm-dd"

  where sortAuthors = intercalate " & " . sort . splitOn " & "

        empty "" = Nothing
        empty t  = Just t

        set "" = False
        set _  = True

        toDate t = if null t
                   then Just Nothing
                   else case toDay t of
                          Just d  -> Just $ Just UTCTime { utctDay = d, utctDayTime = 0 }
                          Nothing -> Nothing

        toDay t = case map (readMaybe . unpack) $ splitOn "-" t of
                    [Just y, Just m, Just d] -> Just $ fromGregorian (fromIntegral y) m d
                    _ -> Nothing

-------------------------

-- |Upload the cover image for a book, returning its path
uploadCover :: RequestProcessor Sitemap (Maybe Text)
uploadCover = do
  isbn <- param' "isbn" ""
  file <- lookup "cover" <$> askFiles

  case file of
    Just f@(FileInfo _ _ c)
      | BL.null c -> return Nothing
      | otherwise -> Just <$> save ["covers", unpack isbn] f
    Nothing -> return Nothing

  where
  save fbits (FileInfo name _ content) = do
    fileroot <- conf "bookdb" "file_root"
    let ext    = takeExtension (map (chr . fromIntegral) $ B.unpack name)
    let path   = joinPath $ fileroot : fbits
    let fname' = path ++ ext

    liftIO $ BL.writeFile fname' content

    return . pack $ takeFileName fname'
