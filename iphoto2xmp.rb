#!/usr/bin/env ruby
# encoding: UTF-8

# Export an Apple iPhoto image library to a new directory (using hardlinks)
# with all metadata saved in XMP sidecar files.
#
# Requires:
# * Tested with Ruby 2.1 and 2.2, not below. Please report errors.
# * gems: see below 'require' list
#
# Usage:
#   ruby iphoto2xmp.rb "~/Pictures/My iPhoto library" "~/Pictures/Export Here"
#
##########################################################################
#
# TODO:
#
# * Export location 'names'
#   Database/Properties.apdb::RKPlace, RKPlace:: 
#   => Properties.apdb::RKPlace, RKPlaceName(placeId -> RKPlace.modelId)
#
# * Group Modified/Original photos in XMP sidecars
#   => from RKVersion.isOriginal und masterUuid
#
# * Export photos in Albums as "Album/XXX" Keywords.
#
# * Export Smart Albums rules into a text file so that they can be recreated.
#
# * Export Slideshows, Calendars, Cards, Books etc. at least as keyword collections.
#
# * Group RAW and JPG files? -> https://gist.github.com/nudomarinero/af88acf44868a9e5bcdc
#                               -> INSERT into ImageRelations VALUES (?, ?, 2) [...]
#   or: "Group Selected by Time" in Digikam (= manually)
#
#######################################################################

require 'progressbar'       # just eye candy
require 'find'
require 'fileutils'
require 'sqlite3'
require 'time'              # required to convert integer timestamps
require 'cfpropertylist'    # required to read binary plist blobs in SQLite3 dbs, 'plist' gem can't do this
require 'erb'               # template engine
require 'pp'                # to pretty print PList extractions

EXIFTOOL = `which exiftool`.chop
if EXIFTOOL == ''
  puts "Can't find exiftool in PATH. You can obtain it from\n  http://owl.phy.queensu.ca/~phil/exiftool/"
  exit 1
end

iphotodir = ARGV[0]
outdir = ARGV[1]

unless iphotodir && outdir
  puts "Usage: #{$0} ~/Pictures/iPhoto\\ Library ~/Pictures/OutputDir"
  exit 1
end

File.directory?(outdir) || Dir.mkdir(outdir)


# just some eye candy for output
class String; def bold; "\e[1m#{self}\e[21m" end; end


# Link photo (original or modified version) to destination directory
def link_photo(basedir, outdir, photo, imgfile, origfile)
  imgpath  = "#{basedir}/#{imgfile}"
  destpath = photo['rollname']  ?  ("#{outdir}/#{photo['rollname']}/#{File.basename(imgpath)}")  :  "#{outdir}#{imgfile}"
  destdir  = File.dirname(destpath)
  if origfile and File.exist?(destpath) and File.size?(imgpath) != File.size?("#{basedir}/#{origfile}")
    # assume modified version has the same filename -> append "_v1" to basename to avoid overwriting
    destpath.sub!(/\.([^.]*)$/, '_v1.\1')
  end
  File.directory?(destdir) || FileUtils.mkpath(destdir)
  if File.exist?(imgpath)
    $known[imgpath] = true
    File.exist?(destpath)  ||  FileUtils.ln(imgpath, destpath)
  else
    $missing.puts(imgpath)
    $problems = true
  end
  # Work out the XMP sidecar location
  # Without extension: File.dirname(destpath) + '/' + File.basename(destpath, File.extname(destpath)) + ".xmp"
  # With extension:
  "#{destpath}.xmp"
end


# iPhoto internally stores times as integer values starting count at 2001-01-01. 
# Correct to be able to use parsed date values.
# Returns "YYYY-MM-DDTHH:MM:SS+NNNN" RFC 3339 string for XMP file.
def parse_date(intdate)
  return "" unless intdate
  diff = Time.parse('2001-01-01 +0100')
  Time.at(intdate + diff.to_i).to_datetime.rfc3339
end


##########################################################################
# Stage 1: Get main image info.
# Cannot use AlbumData.xml because a lot of info is not listed at all in AlbumData.xml but should be exported.
# Examples: keywords, hidden photos, trashcan, location *names*, ...
##########################################################################
print "Phase 1: Reading iPhoto SQLite data (Records: Library ".bold
librarydb = SQLite3::Database.new("#{iphotodir}/Database/apdb/Library.apdb")
librarydb.results_as_hash = true  # gibt [{"modelId"=>1, "uuid"=>"SwX6W9...", "name"=>".."
#keyhead, *keywords = librarydb.execute2("SELECT modelId, uuid, name, shortcut FROM RKKeyword")
#puts "... Available Keywords: #{keywords.collect {|k| k['name'] }.join(", ")}"
masterhead, *masters = librarydb.execute2(
 "SELECT v.modelId AS id
        ,v.masterId AS master_id
        ,v.name AS caption 
        ,f.name AS rollname
        ,f.modelId AS roll
        ,v.uuid AS uuid
        ,m.uuid AS master_uuid        -- master (unedited) image. Required for face rectangle conversion.
        ,v.versionNumber AS version_number  -- 1 if edited image, 0 if original image
     -- ,v.masterUuid AS master_uuid  -- master (unedited) image. Required for face rectangle conversion.
        ,v.mainRating AS rating       -- TODO: Rating is always applied to the master image, not the edited one
        ,m.type AS mediatype          -- IMGT, VIDT
        ,m.imagePath AS imagepath     -- 2015/04/27/20150427-123456/FOO.RW2, yields Masters/$imagepath and
                                      -- Previews/dirname($imagepath)/$uuid/basename($imagepath)
        ,v.imageDate AS date          -- for edited or rotated or converted images, this contains DateTimeModified!
        ,m.imageDate AS datem         --
        ,m.fileCreationDate AS datem_creation
        ,m.fileModificationDate AS datem_mod
        ,replace(i.name, ' @ ', 'T') AS date_import -- contains datestamp of import procedure for a group of files 

        ,v.imageTimeZoneName AS timezone
        ,v.exifLatitude AS latitude
        ,v.exifLongitude AS longitude
        ,v.isHidden AS hidden
        ,v.isFlagged AS flagged
        ,v.isOriginal AS original
        ,m.isInTrash AS in_trash
        ,v.masterHeight AS master_height        -- Height of original image (master)
        ,v.masterWidth AS master_width          -- Width of original image (master)
        ,v.processedHeight AS processed_height  -- Height of processed (eg. cropped, rotated) image
        ,v.processedWidth AS processed_width    -- Width of processed (eg. cropped, rotated) image

        ,v.overridePlaceId AS place_id          -- modelId of Properties::RKPlace
   FROM RKVersion v
    LEFT JOIN RKFolder f ON v.projectUuid=f.uuid
    LEFT JOIN RKMaster m ON m.uuid = v.masterUuid
    LEFT JOIN RKImportGroup i ON m.importGroupUuid = i.uuid
 ")
print "#{masters.count}; "

# TODO: Add iPhoto <9.1(?) type notes to Events. Only in main iPhoto Library, not in test library.
notehead, notes = librarydb.execute2("SELECT * from RKNote")

propertydb = SQLite3::Database.new("#{iphotodir}/Database/apdb/Properties.apdb")
propertydb.results_as_hash = true
placehead, *places = propertydb.execute2("SELECT 
  p.modelId, p.uuid, p.defaultName, p.minLatitude, p.minLongitude, p.maxLatitude, p.maxLongitude, p.centroid, p.userDefined 
  FROM RKPlace p");
# placehead, *places = propertydb.execute2("SELECT p.modelId, p.uuid, p.defaultName, p.minLatitude, p.minLongitude, p.maxLatitude, p.maxLongitude, p.centroid, p.userDefined, n.language, n.description FROM RKPlace p INNER JOIN RKPlaceName n ON p.modelId=n.placeId");
placelist = places.inject({}) {|h,place| h[place['modelId']] = place; h }
print "Properties (#{places.count} places; "

# Get description text of all photos.
deschead, *descs = propertydb.execute2("SELECT
  i.modelId AS id, i.versionId AS versionId, i.modDate AS modDate, s.stringProperty AS string
FROM RKIptcProperty i LEFT JOIN RKUniqueString s ON i.stringId=s.modelId
WHERE i.propertyKey = 'Caption/Abstract' ORDER BY versionId")
photodescs = descs.inject({}) {|h,desc| h[desc['versionId']] = desc['string']; h }
# FIXME: strictly speaking, this is the date of adding the description, not the last edit date
photomoddates = descs.inject({}) {|h,desc| h[desc['versionId']] = desc['modDate']; h }
print "Description #{descs.count}; "

facedb = SQLite3::Database.new("#{iphotodir}/Database/apdb/Faces.db")
facedb.results_as_hash = true
puts "Faces)."

#puts "descs = #{descs.inspect}"
#puts "photodescs = #{photodescs.inspect}"
#puts "placelist = #{placelist.inspect}"


#
# Stage 2: Big loop through all photos
#
basedir = iphotodir
puts "Phase 2/3: Exporting iPhoto archive\n  from #{basedir}\n  to   #{outdir}".bold
#bar = ProgressBar.new("Exporting", masters.length)

$missing = File.open("#{outdir}/missing.log","w")
$problems = false
$known = Hash.new
done_xmp = Hash.new
xmp_template = File.read("#{File.expand_path(File.dirname(__FILE__))}/iphoto2xmp_template.xmp.erb")

# iPhoto almost always stores a second version (Preview) of every image. In my case, out of 41000 images
# only four had just a single version and one had six versions (print projects). So we can safely assume
# one 'original' and one 'modified' version exist of each image and just loop through the master images.
masters.each do |photo|

  origpath = "Masters/#{photo['imagepath']}"
  
  # doesn't work, various info in RKVersion is different (eg. caption)
  # next if $known["#{basedir}/#{origpath}"]
  # Preview can be mp4, mov, jpg, whatever - but not RAW/RW2, it seems.
  modpath = "Previews/#{File.dirname(photo['imagepath'])}/#{photo['uuid']}/#{File.basename(photo['imagepath']).gsub(/PNG$|JPG$|RW2$/, 'jpg')}"
  origxmppath = link_photo(basedir, outdir, photo, origpath, nil)
  next if done_xmp[origxmppath]    # do not overwrite master XMP twice
  # link_photo needs origpath to do size comparison for modified images
  # only perform link_photo for "non-videos" and when a modified image should exist
  # since iPhoto creates "link mp4" files without real video content for "modified" videos (useless)
  if photo['version_number'].to_i > 0 and photo['mediatype'] != 'VIDT'
    modxmppath  = link_photo(basedir, outdir, photo, modpath, origpath) 
  end

  # FIXME: Fix size of RW2 files (incorrectly set to 3776x2520, but Digikam sees 3792x2538) (Panasonic LX3)
  # TODO: Get real size of RW2 files (dcraw -i -v $FILE | grep "Image Size" | ...) and use that
  if photo["imagepath"] =~ /RW2$/ and photo["master_height"].to_i == 2520
    photo["raw_factor_h"] = 2538.0 / photo["master_height"].to_f   # for converting face positions
    photo["raw_factor_w"] = 3792.0 / photo["master_width"].to_f
    #photo["raw_factor_h"] = 1.01
    #photo["raw_factor_w"] = 1.01
    photo["master_height"] = 2538    # incorrect. iPhoto always uses its own internal (wrong) sizes for crop calculations
    photo["master_width"] = 3792
  else
    photo["raw_factor_h"] = 1               # Dummy
    photo["raw_factor_w"] = 1
  end

  @date = parse_date(photo['date'])
  @date_master = parse_date(photo['datem'])
  puts "##{photo['id']}(##{photo['master_id']}): #{photo['caption']}, #{photo['uuid'][0..9]}…/#{photo['master_uuid'][0..9]}…, create: #{@date_master} / edit: #{@date}".bold
  puts "  Desc: #{photodescs[photo['id'].to_i]}"  if photodescs[photo['id'].to_i]
  puts "  Orig: #{photo["master_height"]}x#{photo["master_width"]} (#{photo["raw_factor_h"]}/#{photo["raw_factor_w"]}), #{origpath} (#{File.exist?("#{basedir}/#{origpath}")})"
  puts "  Mod : #{photo["processed_height"]}x#{photo["processed_width"]}, #{modpath}, (#{File.exist?("#{basedir}/#{modpath}")})" if File.exist?("#{basedir}/#{modpath}")

  #
  # Build up objects with the metadata in using an ERB template. 
  # LibXML is too complicated and Nokogiri can't properly handle RDF type documents. :( 
  #
  xmp = xmp_template.dup

  # The image caption in iPhoto is always applied to the edited image (if any), not the master.
  # Apply it to both images if found in edited image.
  #@title = photo['title']
  @caption = photo['caption']
  #@uuid = photo['version_number'].to_i > 0 ? photo['uuid'] : photo['master_uuid']   # avoid duplicate uuids
  @uuid = photo['master_uuid']    # will be changed further down for version > 1
  @description = photodescs[photo['id'].to_i]

  # Rating is always applied to the edited image (not the master). Apply to both!
  @rating = photo['rating']       # Value 0 (no rating) and 1..5, like iPhoto
  @hidden = photo['hidden']       # set PickLabel to hidden flag -> would set value '1' which means 'rejected'
  @flagged = photo['flagged']     # set ColorLabel to flagged, would set value '1' which means 'red'
  @date_meta = parse_date(photomoddates[photo['id']])

  # TODO: save GPS location info in XMP file (RKVersion::overridePlaceId -> Properties::RKPlace
  #       (user boundaryData?)
  @longitude = photo['longitude']
  @latitude  = photo['latitude']
  if p = placelist[photo['place_id']]
    @gpscity = ''
    @gpsstate = ''
    @gpscountryname = ''
    @gpslocation = p['defaultName']
    @gps3lettercountrycode = ''
  end


  # Get keywords. Convert iPhoto specific flags as keywords too.
  @keylist = Array.new
  photokwheader, *photokw = librarydb.execute2("SELECT
      RKVersion.uuid AS uuid
     ,RKKeyword.modelId AS modelId
     ,RKKeyword.name AS name
   FROM RKKeywordForVersion INNER JOIN RKversion ON RKKeywordForVersion.versionId=RKVersion.modelId
                            INNER JOIN RKKeyword ON RKKeywordForVersion.keywordId=RKKeyword.modelId
   WHERE RKVersion.uuid='#{photo['uuid']}'")
  @keylist = photokw.collect {|k| k['name'] }
  @keylist << "iPhoto/Hidden" if photo["hidden"]==1
  @keylist << "iPhoto/Flagged" if photo["flagged"]==1
  @keylist << "iPhoto/Original" if photo["original"]==1
  @keylist << "iPhoto/inTrash" if photo["in_trash"]==1
  puts "  Tags: #{photokw.collect {|k| "#{k['name']}(#{k['modelId']})" }.join(", ")}" unless photokw.empty?


  # Get edits. Discard pseudo-Edits like RAW decoding and (perhaps?) rotations
  # but save the others in the XMP edit history.
  edithead, *edits = librarydb.execute2(
    "SELECT a.name AS adj_name    -- RKRawDecodeOperation, RKStraightenCropOperation, ...
                                  -- RAW-Decoding and Rotation are not edit operations, strictly speaking
           ,a.adjIndex as adj_index
           ,a.data as data
     FROM RKImageAdjustment a
    WHERE a.versionUuid='#{photo['uuid']}'")
  # TODO: Save iPhoto/iOS edit operations in XMP structure (digiKam:history?)
 

  # Link: Faces.apdb::RKDetectedFace::masterUuid == Library.apdb::RKMaster::uuid
  facehead, *faces = facedb.execute2(
    "SELECT d.modelId             -- primary key
         ,d.uuid AS detect_uuid   -- primary key
         ,d.masterUuid            -- --> Library::RKMaster::uuid
         ,d.faceKey               -- --> RKFaceName::faceKey
         ,d.topLeftX    ,d.topLeftY    ,d.topRightX    ,d.topRightY     -- *relative* coordinates within *original* image (0..1)
         ,d.bottomLeftX ,d.bottomLeftY ,d.bottomRightX ,d.bottomRightY  -- *relative* coordinates within *original* image (0..1)
         ,d.confidence
         ,d.rejected
         ,d.ignore
         ,n.uuid AS name_uuid
         ,n.name AS name
         ,n.fullName AS full_name
         ,n.email AS email
      FROM RKDetectedFace d
      LEFT JOIN RKFaceName n ON n.faceKey=d.faceKey
      WHERE d.masterUuid='#{photo['master_uuid']}'
      ORDER BY d.modelId");  # LEFT JOIN because we also want unknown faces

  # If photo was edited, check if dimensions were changed (crop, rotate, iOS edit)
  # since this would require recalculation of the face rectangle locations.
  # Unfortunately, the crop info is saved in a PropertyList blob within the 'data' column of the DB.
  # Can it be more cryptic please? Who designs this crap anyway?
  crop_startx = crop_starty = crop_width = crop_height = 0
  if photo['version_number'].to_i > 0
    print "  Edit: " #{edits.collect{|e| e['adj_name'] }.join(",").gsub(/RK|Operation/, '')}"
    edits.each do |edit|
      check = false
      edit_plist_hash = CFPropertyList.native_types(CFPropertyList::List.new(data: edit['data']).value)
      # save raw PropertyList data in additional sidecar file for later analysis
      File.open(modxmppath.gsub(/xmp/, "plist_#{edit['adj_name']}"), 'w') do |j|
        PP.pp(edit_plist_hash, j)
      end
      
      case edit['adj_name'] 
        when "RKCropOperation"
          # image was cropped, region metadata cannot be calculated directly, need crop info
          check = edit_plist_hash["$objects"][13] == "inputRotation"
          # eg. 1612, 2109, 67, 1941 - crop positions
          crop_startx = edit_plist_hash["$objects"][20]    # xstart: position from the left
          crop_starty = edit_plist_hash["$objects"][23]    # ystart: position from the bottom!
          crop_width  = edit_plist_hash["$objects"][22]    # xsize:  size in pixels from xstart
          crop_height = edit_plist_hash["$objects"][24]    # ysize:  size in pixels from ystart
          print "Crop (#{crop_startx}x#{crop_starty}+#{crop_width}+#{crop_height}), "
        when "RKStraightenCropOperation"
          # image was straightened and thus implicitly cropped, region metadata must be adjusted
          # TODO: calculate region shift from rotational angle.
          check = edit_plist_hash["$objects"][9] == "inputRotation"
          # factor examples: 1.04125 ~ 1.0° ; 21.142332 ~ 5.2° ; 19.0507 ~ -19,1°
          crop_rotation_factor = edit_plist_hash["$objects"][10]    # inputRotation
          print "StraightenCrop (#{crop_rotation_factor}), "
        when "DGiOSEditsoperation"
          # TODO: image was edited in iOS which creates its own XMP file (with proprietary aas and crs tags).
          print "iOSEdits (???), "
        else
          # No region adjustment required for RawDecode, Whitebalance, ShadowHighlight, Exposure, NoiseReduction,
          # ProSharopen, iPhotoRedEye, Retouch, iPhotoEffects, and possibly others
      end
    end # edits.each
    puts ""
  end

  # Add faces to BOTH original and edited images.
  # If edited image is cropped, modify face rectangle positions accordingly.
  # TODO: both Library::RKVersionFaceContent and Faces::RKDetectedFace contain face rectangle data.
  # Which is better?
  xmp_mod = xmp.dup

  @orig_faces = faces.collect do |face|
    topleftx = "%.8f" % (face['topLeftX'].to_f)
    toplefty = "%.8f" % (1-face['topLeftY'].to_f)   # iPhoto counts Y dimension from the bottom, thus "1-y"
    width    = "%.8f" % ((face['bottomRightX'] - face['topLeftX']).abs)
    height   = "%.8f" % ((face['bottomRightY'] - face['topLeftY']).abs)
    centerx  = "%.8f" % (face['topLeftX'].to_f + width.to_f/2)
    centery  = "%.8f" % (1-face['topLeftY'].to_f + height.to_f/2)
    { 'topleftx' => topleftx, 'toplefty' => toplefty,
      'centerx'  => centerx,  'centery' => centery, 'width' => width, 'height' => height,
      'full_name' => face['full_name'] || "Unknown", 'email' => face['email'] }
  end
  @orig_faces.each {|f|
    puts "  FaceOrig: #{f['topleftx']} / #{f['toplefty']} (#{f['centerx']} / #{f['centery']}) +#{f['width']} +#{f['height']};  #{f['full_name']}\t "
  }

  # RW2 files have no definite resolution (res in iPhoto is buggy / wrong) so they need extra treatment.
  @rw2_faces = faces.collect do |face|
    topleftx = "%.8f" % (face['topLeftX'].to_f * photo['raw_factor_w'].to_f)
    toplefty = "%.8f" % ((1-face['topLeftY'].to_f) * photo['raw_factor_h'].to_f)   # iPhoto counts Y dimension from the bottom, thus "1-y"
    width    = "%.8f" % ((face['bottomRightX'] - face['topLeftX']).abs * photo['raw_factor_w'].to_f)
    height   = "%.8f" % ((face['bottomRightY'] - face['topLeftY']).abs * photo['raw_factor_h'].to_f)
    centerx  = "%.8f" % ((face['topLeftX'].to_f * photo['raw_factor_w'].to_f) + width.to_f/2)
    centery  = "%.8f" % ((1-face['topLeftY'].to_f) * photo['raw_factor_h'].to_f + height.to_f/2)
    { 'topleftx' => topleftx, 'toplefty' => toplefty,
      'centerx'  => centerx,  'centery' => centery, 'width' => width, 'height' => height,
      'full_name' => face['full_name'] || "Unknown", 'email' => face['email'] }
  end
  @rw2_faces.each {|f|
    puts "  Face_RW2: #{f['topleftx']} / #{f['toplefty']} (#{f['centerx']} / #{f['centery']}) +#{f['width']} +#{f['height']};  #{f['full_name']}\t "
  }

  # Cropped faces need converted rectangle data. We have
  #  * topleftx/y (0..1) relative face location inside original image (0..1)
  #  * crop_startx/y     absolute pixels, y from bottom(!)
  #  * photo[processed_h/w] absolute pixels
  #
  @crop_faces = []
  @crop_faces = faces.collect do |face|
    topleftx = "%.8f" % ((face['topLeftX'] * photo['master_width'].to_i - crop_startx) / crop_width)    # OK
    toplefty = "%.8f" % (((1-face['topLeftY']) * photo['master_height'].to_i - (photo['master_height'].to_i-crop_height-crop_starty)) / crop_height)
    width    = "%.8f" % ((face['bottomRightX']-face['topLeftX']).abs * photo['master_width'].to_i / crop_width)
    height   = "%.8f" % ((face['bottomRightY']-face['topLeftY']).abs * photo['master_height'].to_i / crop_height)
    centerx  = "%.8f" % (face['topLeftX'].to_f + width.to_f/2)
    centery  = "%.8f" % (1-face['topLeftY'].to_f + height.to_f/2)
    puts "  FaceCrop: topLeftX/Y=#{face['topLeftX']}/#{face['topLeftY'].to_f}, master_w/h=#{photo['master_width']}/#{photo['master_height']}, crop_startx/y=#{crop_startx}/#{photo['master_height'].to_i-crop_starty}, crop_w/h=#{crop_width}/#{crop_height}"
    { 'topleftx' => topleftx, 'toplefty' => toplefty,
      'centerx'  => centerx,  'centery' => centery, 'width' => width, 'height' => height,
      'full_name' => face['full_name'] || "Unknown", 'email' => face['email'] }
  end if crop_startx > 0
  @crop_faces.each {|f|
    puts "  FaceCrop: #{f['topleftx']} / #{f['toplefty']} (#{f['centerx']} / #{f['centery']}) +#{f['width']} +#{f['height']};  #{f['full_name']}\t "
  }

  # TODO: additionally specify modified image as second version of original file in XMP (DerivedFrom?)
  unless(File.exist?(origxmppath))
    @faces = photo["imagepath"] =~ /RW2$/ ? @rw2_faces : @orig_faces
    j = File.open(origxmppath, 'w')
    j.puts(ERB.new(xmp, 0, ">").result)
    j.close
    done_xmp[origxmppath] = true
  end
  if photo['version_number'].to_i == 1 and modxmppath and !File.exist?(modxmppath)
    @faces = crop_startx > 0 ? @crop_faces : @orig_faces
    @uuid = photo['uuid']             # for this image, use modified image's uuid
    j = File.open(modxmppath,  'w')
    j.puts(ERB.new(xmp_mod, 0, ">").result)
    j.close
  end

#  bar.inc
end

$missing.close
if $problems
  puts "\nOne or more files were missing from your iTunes library!"
  puts File.read("#{outdir}/missing.log")
  puts "You can find this list in missing.log in the output directory."
else
  File.unlink("#{outdir}/missing.log")
end

#
# Stage 3: 
#
puts "\n\nPhase 3/3: Searching for lost masters"

Find.find("#{iphotodir}/Masters").each do |file|
  ext = File.extname(file)
  if ext.match(/\.(PNG|BMP|RAW|RW2|CR2|CRW|TIF|DCR|DNG)/i)
    if !$known[file]
      imgfile = file.sub(/^#{iphotodir}\/Masters\//i,'')
      destfile = "#{outdir}/Lost and Found/#{imgfile}"
      destdir = File.dirname(destfile)
      FileUtils.mkpath(destdir) unless File.directory?(destdir)
      FileUtils.ln(file, destfile) unless File.exists?(destfile)
      puts "  Found #{imgfile}"
    end
  end
end

# vim:set ts=2 expandtab:
