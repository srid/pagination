-- |
-- Module      :  Data.Pagination
-- Copyright   :  © 2016 Mark Karpov
-- License     :  BSD 3 clause
--
-- Maintainer  :  Mark Karpov <markkarpov@openmailbox.org>
-- Stability   :  experimental
-- Portability :  portable
--
-- Framework-agnostic pagination boilerplate.

{-# LANGUAGE CPP                #-}
{-# LANGUAGE DeriveDataTypeable #-}
{-# LANGUAGE DeriveGeneric      #-}
{-# LANGUAGE RecordWildCards    #-}

module Data.Pagination
  ( -- * Pagination settings
    Pagination
  , mkPagination
  , pageSize
  , pageIndex
    -- * Paginated data
  , Paginated
  , paginate
  , paginatedItems
  , paginatedPagination
  , paginatedPagesTotal
  , paginatedItemsTotal
  , hasOtherPages
  , pageRange
  , pageRangeFull
  , hasPrevPage
  , hasNextPage
  , backwardEllip
  , forwardEllip )
where

import Control.DeepSeq
import Control.Monad.Catch
import Data.Data (Data)
import Data.List.NonEmpty (NonEmpty (..))
import Data.Semigroup ((<>))
import Data.Typeable (Typeable)
import GHC.Generics
import Numeric.Natural
import qualified Data.List.NonEmpty as NE

#if !MIN_VERSION_base(4,8,0)
import Control.Applicative
import Data.Foldable (Foldable (..))
import Data.Traversable (Traversable (..))
import Prelude hiding (foldr)
#endif

-- | The data type represents settings that are required to organize data in
-- paginated form.

data Pagination = Pagination Natural Natural
  deriving (Eq, Show, Data, Typeable, Generic)

instance NFData Pagination

-- | Create a 'Pagination' value. Throws 'PaginationException'.

mkPagination :: MonadThrow m
  => Natural           -- ^ Page size
  -> Natural           -- ^ Page index
  -> m Pagination      -- ^ The pagination settings
mkPagination size index
  | size  == 0 = throwM ZeroPageSize
  | index == 0 = throwM ZeroPageIndex
  | otherwise  = return (Pagination size index)

-- | Get page size (maximum number of items on a page) from a 'Pagination'.

pageSize :: Integral n => Pagination -> n
pageSize (Pagination size _) = fromIntegral size

-- | Get page index from a 'Pagination'.

pageIndex :: Integral n => Pagination -> n
pageIndex (Pagination _ index) = fromIntegral index

-- | Exception indicating various problems when working with paginated data.

data PaginationException
  = ZeroPageSize
  | ZeroPageIndex
  deriving (Eq, Show, Data, Typeable, Generic)

instance NFData PaginationException
instance Exception PaginationException

-- | Data in paginated form.

data Paginated a = Paginated
  { pgItems      :: [a]
  , pgPagination :: Pagination
  , pgPagesTotal :: Natural
  , pgItemsTotal :: Natural
  } deriving (Eq, Show, Data, Typeable, Generic)

instance NFData a => NFData (Paginated a)

instance Functor Paginated where
  fmap f p@Paginated {..} = p { pgItems = fmap f pgItems }

instance Applicative Paginated where
  pure x  = Paginated [x] (Pagination 1 1) 1 1
  f <*> p = p { pgItems = pgItems f <*> pgItems p }

instance Foldable Paginated where
  foldr f x = foldr f x . pgItems

instance Traversable Paginated where
  traverse f p =
    let g p' xs = p' { pgItems = xs }
    in g p <$> traverse f (pgItems p)

-- | Create paginated data.

paginate :: (Monad m, Integral n)
  => Pagination        -- ^ Pagination options
  -> Natural           -- ^ Total number of items
  -> (n -> n -> m [a])
     -- ^ The element producing callback. The function takes arguments:
     -- offset and limit.
  -> m (Paginated a)   -- ^ The paginated data
paginate p@(Pagination size index') totalItems f = do
  items <- f (fromIntegral offset) (fromIntegral size)
  return Paginated
    { pgItems      = items
    , pgPagination = p
    , pgPagesTotal = totalPages
    , pgItemsTotal = totalItems }
  where
    (whole, rems) = totalItems `quotRem` size
    totalPages    = max 1 (whole + if rems == 0 then 0 else 1)
    index         = min index' totalPages
    offset        = (index - 1) * size

-- | Get subset of items for current page.

paginatedItems :: Paginated a -> [a]
paginatedItems = pgItems
{-# INLINE paginatedItems #-}

-- | Get 'Pagination' parameters that were used to create this paginated result.

paginatedPagination :: Paginated a -> Pagination
paginatedPagination = pgPagination
{-# INLINE paginatedPagination #-}

-- | Get total number of pages in this collection.

paginatedPagesTotal :: Integral n => Paginated a -> n
paginatedPagesTotal = fromIntegral . pgPagesTotal
{-# INLINE paginatedPagesTotal #-}

-- | Get total number of items in this collection.

paginatedItemsTotal :: Integral n => Paginated a -> n
paginatedItemsTotal = fromIntegral . pgItemsTotal
{-# INLINE paginatedItemsTotal #-}

-- | Test whether there are other pages.

hasOtherPages :: Paginated a -> Bool
hasOtherPages Paginated {..} = pgPagesTotal > 1
{-# INLINE hasOtherPages #-}

-- | Is there previous page?

hasPrevPage :: Paginated a -> Bool
hasPrevPage Paginated {..} = pageIndex pgPagination > (1 :: Natural)
{-# INLINE hasPrevPage #-}

-- | Is there next page?

hasNextPage :: Paginated a -> Bool
hasNextPage Paginated {..} = pageIndex pgPagination < pgPagesTotal
{-# INLINE hasNextPage #-}

-- | Get range of pages to show before and after current page. This does not
-- necessarily include the first and the last pages (they are supposed to be
-- shown in all cases). Result of the function is always sorted.

pageRange
  :: Paginated a       -- ^ Paginated data
  -> Natural           -- ^ Number of pages to show before and after
  -> NonEmpty Natural  -- ^ Page range
pageRange Paginated {..} 0 = NE.fromList [pageIndex pgPagination]
pageRange Paginated {..} n =
  let len   = min pgPagesTotal (n * 2 + 1)
      index = pageIndex pgPagination
      shift | index <= n                = 0
            | index >= pgPagesTotal - n = pgPagesTotal - len
            | otherwise                 = index - n - 1
  in (+ shift) <$> NE.fromList [1..len]

-- | Just like 'pageRange', but always includes first and last pages.

pageRangeFull :: Integral n
  => Paginated a       -- ^ Paginated data
  -> Natural           -- ^ Number of pages to show before and after
  -> NonEmpty n        -- ^ Page range
pageRangeFull p n = fromIntegral <$>
  (if NE.last pr == total then pr else pre <> (total :| []))
  where
    pr    = pageRange p n
    total = pgPagesTotal p
    pre   = if NE.head pr == 1 then pr else NE.cons 1 pr

-- | Backward ellipsis appears when page range (pages around current page to
-- jump to) has gap between its beginning and the first page.

backwardEllip
  :: Paginated a       -- ^ Paginated data
  -> Natural           -- ^ Number of pages to show before and after
  -> Bool
backwardEllip p n = NE.head (pageRange p n) > 2
{-# INLINE backwardEllip #-}

-- | Forward ellipsis appears when page range (pages around current page to
-- jump to) has gap between its end and the last page.

forwardEllip
  :: Paginated a       -- ^ Paginated data
  -> Natural           -- ^ Number of pages to show before and after
  -> Bool              -- ^ Do we have forward ellipsis?
forwardEllip p@Paginated {..} n = NE.last (pageRange p n) < pred pgPagesTotal
{-# INLINE forwardEllip #-}
