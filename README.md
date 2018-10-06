# iphoto2xmp
Export an Apple iPhoto image library to a new directory (using hardlinks) with all metadata saved in XMP sidecar files.
This is useful if you do not want your iPhoto library moved to a cloud-centric Photos app with less features.
XML sidecar files are used by many asset management tools, e.g. Adobe Lightroom, Photoshop and so on - so the result should be editable and useful in a lot of different tools.

This script will export your Apple iPhoto library to a new directory structure (folders according to iPhoto "Events") using a standard metadata format (XMP sidecar files) wherever possible, so that you can import your image library to a different application (DAM = Digital Asset Management) and keep all your image metadata intact.

Hard links are used to copy the actual images and videos, so very little additional disk space is required. This requires that the target directory is on the same volume as the iPhoto library.

Original images and your iPhoto library are not modified in any way.

You do not need to run this on OS X to read the iPhoto library, you only need a copy of the library. Tested on Linux (Ubuntu 14.04).

Apple's public AlbumData.xml API does not expose all of this information, so this script uses SQLite3 to access the iPhoto library data directly.

EXIF and other data which was in the original images is of course preserved but *NOT* copied to the XMP sidecar file.


## Requirements

The main Ruby source file `iphoto2xmp.rb` lists the following requirements. Some of these have to be installed before using the script.

    require 'progressbar'       # required for eye candy during conversion
    require 'find'              # required to find orphaned images
    require 'fileutils'         # required to move and link files around 
    require 'sqlite3'           # required to access iPhoto database
    require 'time'              # required to convert integer timestamps
    require 'exifr'             # required to read orientation metadata from image files
    require 'cfpropertylist'    # required to read binary plist blobs in SQLite3 dbs, 'plist' gem can't do this
    require 'erb'               # template engine
    require 'pp'                # to pretty print PList extractions

For Ubuntu (I tested 14.04, 16.04 and 18.04 with Ruby 1.9, 2.2 and 2.5), this means e.g.

    sudo apt-get install ruby ruby-dev libsqlite3-dev gcc make git
    sudo gem install sqlite3 progressbar CFPropertyList exifr
    git clone https://github.com/jensb/iphoto2xmp.git
    cd iphoto2xmp
    
For Mac OS X Sierra, MacPorts and Ruby 2.5, this means 

    sudo port install ruby25
    sudo gem2.5 install sqlite3 progressbar fileutils CFPropertyList exifr

Note that the default installed Ruby 2.0 on Mac OS Sierra will *not* work, since Apple ships this with outdated OpenSSL libraries that cannot install Gems any more, because rubygems.org now prohibits TLSv1 connections (see https://github.com/rubygems/rubygems/issues/1912).

## Usage

1. Download `iphoto2xmp.rb` and `iphoto2xmp_template.xmp.erb` (or clone the repository using `git`, like described above) and then run it as follows: 

    ruby iphoto2xmp.rb "~/Pictures/My iPhoto library" "~/Pictures/Export Here"

Use a `DEBUG` environment variable to print out debugging information. For example, `DEBUG=1` will print out basic information about all found images. `DEBUG=3` will print out all metadata found in all images including faces - this is a LOT of text. If you run the 'bash' shell, you can type

    DEBUG=1 ruby iphoto2xmp.rb "~/Pictures/My iPhoto library" "~/Pictures/Export Here"

Otherwise set DEBUG=1 before executing the script according to your shell's syntax.
The `DEBUG` variable is nothing special for Ruby, it is just a variable used in the script to decide how much information to show during operation.

2. Open your favorite DAM (Digital Asset Management - e.g. images) application, e.g. Digikam, and point it to the export target folder.
In Digikam, this folder can be added as a "collection". In Digikam, you also need to enable "Read metadata from sidecar files" in the settings under "Metadata".


## Metadata debugging

Sometimes iPhoto displays garbage dates in the "Edited:" and "Imported:" metadata fields.
If you are unsure whether date metadata (taken, imported, edited, ...) are imported correctly, 
you can check what iphoto2xmp detects. Create a CSV file like below (e.g. "dates.csv"):

    caption,v_id,taken,edited,imported
    IMG_0195,123,2002-01-24 15:49:01 +1,2002-01-25 14:01:25 +1,2001-01-25 13:49:29 +1
    IMG_0196,124,2002-01-24 16:49:01 +1,2002-01-25 15:01:25 +1,2001-01-25 14:49:29 +1
    ...

This file contains the dates that iPhoto displays to the user - date taken, date edited and date imported.
v_id is the *model_id* column from the *RKVersions* table which is displayed upon export like this (here, it's *456*):

    *456*(123): P11700295.JPG   My_image_Caption    2*  ...

Then feed this file to iphoto2xmp like this:

    DATES=dates.csv ruby iphoto2xmp.rb "~/Pictures/My iPhoto library" "~/Pictures/Export Here"
    
In this mode, iphoto2xmp will:

 * ignore all photos except the ones in the files
 * print out all date values it found in the iPhoto database
 * Try to match the ones with the ones iPhoto displayed
 * Tell you about it
 
This helps debugging when iphoto2xmp displays incorrect date metadata.
Always use this mode to report issues about timestamps.


## Credits
The original idea was taken from https://gist.github.com/lpar/2191225, but the script has been heavily modified to access more iPhoto metadata (not just AlbumData.xml), distinguish between original and modified photos, and not rely on exiftool. This also brings a huge speed improvement.


## Exported Metadata
The script can currently export the following metadata:

 * Image filenames (duh)
 * All EXIF data within the original image (preserved inside the files)
 * Captions / Titles
 * Descriptions
 * Keywords (iPhoto does not use hierarchical tags)
 * Date taken, Date modified (in iPhoto), date imported (into iPhoto) (as EXIF flag "DateTimeDigitized")
 * Event names (used for the folder structure, not exported into XMP)
   Note: photos in a "New Event" (i.e. just imported into iPhoto) will be imported into a "00_ImagesWithoutEvents" directory.
 * GPS coordinates
 * Edited and original images, edit operation (eg. "Crop", "WhiteBalance", ...)
 * Face names and face coordinates
 * Face names and face coordinates in rotated or cropped images
   (TODO: still buggy if the image had EXIF rotation flags set since then iPhoto saves weird position values)
 * Hidden, Starred, Flagged, Editable, Original, isInTrash flags (as tags)
 * iPhoto and iOS edit operations as additional *.plist sidecar files (so far, not all are decoded)
 * Albums as tag collections (Library:RKFolder/RKAlbum, Library:RKAlbumVersion) into "TopLevelAlbums/" tag hierarchy
 * iPhoto's Slideshows, Calendars, Cards, Books as tag collections (to identify which photos were used) into "TopLevelKeepsakes/" tag hierarchy
 * Smart Album rules into a separate text file so they can be recreated in the target application
   (the structure is not decoded yet but can be looked at)
 
Digikam 5.x might require selecting all images and performing an "Item > Reread Image Metadata" operation before all metadata is visible in the application.
It also requires activation of reading from XMP sidecar files (and writing to them if desired).


## Post Mortem operations (Digikam 4+ specific)
Some image properties cannot (properly) be converted into metadata suitable for XMP sidecar files. They must be
patched into the target application's database after the import process. This requires exceuting `sqlite` scripts
**after starting Digikam at least once** and letting it update the image database.

iphoto2xmp writes several SQL scripts into the destination folder which can be executed against the `digikam4.db`
SQLite database after the import. *Note that this should only be done with a backup, in case something goes wrong.*
These might include (depending on what features were used in iPhoto):

 * iPhoto <= 9.1 Event notes (as Album descriptions): `event_notes.sql`
 * Event minimum date and thumbnail (as Album date and thumbnail): `event_metadata.sql`
 * Group original & modified images (as groups & versions): `grouped_images.sql`

Usage for each file (grouped_images.sql as an example):

    sqlite3 ~/Pictures/digikam4.db < grouped_images.sql

If there is no output, everything went fine. If there is a lot of output, there is a problem with the SQL.
Post the output as an issue here on Github.

## Planned Features (TODO)
The script *should* (at some point) also do the following.
Note: This is your chance to fork and create a pull request ;-)

 * Avoid saving duplicate versions of non-modified images (e.g. "RawDecodeOperation" is not a modification)
 * Optionally rotate videos (that have the "Orientation" flag set) so that they display correctly in Digikam.
 * Export iPhoto "hidden" status as group commands and include a dummy image as first image with a "hidden" icon
   (hidden photos are already tagged accordingly so you can do anything you want with them)
 * use XMP DerivedFrom to automatically group "Original" and "Modified" photos from RKVersion.isOriginal und masterUuid
 * GPS coordinate names (Country, City, etc.). These are in Properties.apdb::RKPlace, RKPlaceName
 * Fix face coordinates for EXIF rotated images (see above)
 * export an image's edit history at least as a descriptive text, perhaps as XMP (e.g. digikam:history tag)
 * correctly identify iOS Edit operations (which create their own proprietary XMP sidecar file)


## Orphans, Missing files
The script will additionally identify

 * orphaned images in your iPhoto Library (ie. images which are referenced nowhere) and
 * missing images (images which are in the database but have no associated file).

and copy orphaned images to the output root directory.


## Keywords
iPhoto does not use hierarchical tags, but some users might have created a pseudo-hierarchical structure in iPhoto using dots or slashes, naming tags like "Places/Ottawa" or "People/John Doe". The tags are converted verbatim, so it is up to your new DAM to make sense of these tags. Or fork, write a conversion, and create a pull request! ;-)


## iPhoto Library SQlite3 structure
I plan to document the iPhoto Library structure in this repository when I have the time. Meanwhile, look at the source code comments.


## License
The license of this script is GPL2 as of now. If this causes problems with your intended usage please contact me.

## Contact
Contact me at jens-github@spamfreemail.de or via Github.

