# iphoto2xmp
Export an Apple iPhoto image library to a new directory (using hardlinks) with all metadata saved in XMP sidecar files.

This script will export your Apple iPhoto library to a new directory structure (folders according to iPhoto "Events") using a standard metadata format (XMP sidecar files) wherever possible, so that you can import your image library to a different application (DAM = Digital Asset Management) and keep all your image metadata intact.

Hard links are used to copy the actual images and videos, so very little additional disk space is required. This requires that the target directory is on the same volume as the iPhoto library.

Original images and your iPhoto library are not modified in any way.

You do not need to run this on OS X to read the iPhoto library, you only need a copy of the library. Tested on Linux (Ubuntu 14.04).

Apple's public AlbumData.xml API does not expose all of this information, so this script uses SQLite3 to access the iPhoto library data directly.

EXIF and other data which was in the original images is of course preserved but *NOT* copied to the XMP sidecar file.


## Credits
The original idea was taken from https://gist.github.com/lpar/2191225, but the script has been heavily modified to access more iPhoto metadata (not just AlbumData.xml), distinguish between original and modified photos, and not rely on exiftool. This also brings a huge speed improvement.


## Exported Metadata
The script can currently export the following metadata:

 * Image filenames (duh)
 * All EXIF data within the original image (preserved inside the files)
 * Captions / Titles
 * Descriptions
 * Keywords (iPhoto does not use hierarchical keywords)
 * Event names (used for the folder structure, not exported into XMP)
 * GPS coordinates
 * Edited and original images, edit operation (eg. "Crop", "WhiteBalance", ...)
 * Faces and face coordinates (still buggy for cropped images, see below)
 * Hidden, Starred, Flagged, Editable, Original, isInTrash flags (as keywords)

## Planned Features (TODO)
The script *should* (at some point) also do the following.
Note: This is your chance to fork and create a pull request ;-)

 * export iPhoto (before 9.1(?)) Event notes (TODO: where to?). These are in Library.apdb::RKNote SQLite table.
 * export GPS coordinate names (Country, City, etc.). These are in Properties.apdb::RKPlace, RKPlaceName
 * use XMP DerivedFrom to automatically group "Original" and "Modified" photos.
 * export Albums as "Album/XXX" keyword collections
 * export Smart Album rules into a separate text file so they can be recreated in the target application
 * export iPhoto's Slideshows, Calendars, Cards, Books at least as keyword collections (to identify which photos were used).
 * export an image's edit history at least as a descriptive text, perhaps as XMP (e.g. digikam:history tag)
 * correctly identify and tag face rectangles in rotated or cropped images
 * correctly identify iOS Edit operations (which create their own proprietary XMP sidecar file)


## Orphans, Missing files
The script will additionally identify
 * orphaned images in your iPhoto Library (ie. images which are referenced nowhere) and
 * missing images (images which are in the database but have no associated file).
and optionally copy orphaned images to the export root directory 


## Keywords
iPhoto does not use hierarchical keywords, but some users might have created a pseudo-hierarchical structure in iPhoto using dots or slashes, naming keywords like "Places/Ottawa" or "People/John Doe". The keywords are converted verbatim, so it is up to your new DAM to make sense of these keywords. Or fork, write a conversion, and create a pull request! ;-)


## iPhoto Library SQlite3 structure
I plan to document the iPhoto Library structure in this repository when I have the time. Meanwhile, look at the source code comments.


## Contact
Contact me at jens-github@spamfreemail.de or via Github.

