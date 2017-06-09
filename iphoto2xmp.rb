#!/usr/bin/env ruby
# encoding: UTF-8

# Export an Apple iPhoto image library to a new directory (using hardlinks)
# with all metadata saved in XMP sidecar files.
#
# Requires:
# * Tested with Ruby 1.9, 2.1 and 2.2 on Ubuntu 14.04. Please report errors.
# * gems: see below 'require' list
#
# Usage:
#   ruby iphoto2xmp.rb "~/Pictures/My iPhoto library" "~/Pictures/Export Here"
# or
#   DEBUG=x ruby iphoto2xmp.rb "~/Pictures/My iPhoto library" "~/Pictures/Export Here"
# where "x" is 1, 2, or 3 (higher = more output)
#
##########################################################################

require 'progressbar'       # required for eye candy during conversion
require 'find'              # required to find orphaned images
require 'fileutils'         # required to move and link files around
require 'sqlite3'           # required to access iPhoto database
require 'time'              # required to convert integer timestamps
require 'cfpropertylist'    # required to read binary plist blobs in SQLite3 dbs, 'plist' gem can't do this
require 'erb'               # template engine
require 'pp'                # to pretty print PList extractions

iphotodir = ARGV[0]
outdir = ARGV[1]

unless iphotodir && outdir
  puts "Usage: #{$0} ~/Pictures/iPhoto\\ Library ~/Pictures/OutputDir"
  exit 1
end

File.directory?(outdir) || Dir.mkdir(outdir)


# just some eye candy for output
class String
  def bold; "\e[1m#{self}\e[0m" end
  def red;  "\e[31m#{self}\e[0m" end
  def green;"\e[32m#{self}\e[0m" end
  def yellow;"\e[33m#{self}\e[0m" end
  def blue; "\e[34m#{self}\e[0m" end
  def cyan; "\e[36m#{self}\e[0m" end
  def violet; "\e[35m#{self}\e[0m" end
  def grey; "\e[37m#{self}\e[0m" end
  def sqlclean; self.gsub(/\'/, "''").gsub(/%/, "\%") end
end


# Print debug output, if ENV['DEBUG'] is equal or greater to level passed as parameter.
# levels: 3: debug output,   all found metadata for each photo
#         2: verbose output, most found metadata for each photo
#         1: normal output,  one line with basic info for each photo
#   default: quiet output,   progressbar with percent complete for whole operation
def debug(level, str, newline=true)
  return unless level==0 or (e = ENV['DEBUG'] and e.to_i >= level)
  if newline ; puts str else print str end
end


# Link photo (original or modified version) to destination directory
# TODO: prevent duplicate links from the same original photo.
def link_photo(basedir, outdir, photo, imgfile, origfile)
  imgpath  = "#{basedir}/#{imgfile}"  # source image path, absolute
  if photo['rollname']
    if year = parse_date(photo['roll_min_image_date'], photo['roll_min_image_tz'])
      destpath = "#{outdir}/#{year.strftime("%Y")}/#{photo['rollname']}/#{File.basename(imgpath)}"
    else
      "#{outdir}/#{photo['rollname']}/#{File.basename(imgpath)}"
    end
  else
    "#{outdir}/00_ImagesWithoutEvents/#{imgfile}"
  end
  #destpath = photo['rollname']  ?  "#{outdir}/#{photo['rollname']}/#{File.basename(imgpath)}"
  #                              :  "#{outdir}#{imgfile}"
  destdir  = File.dirname(destpath)
  # if origfile differs from imgfile, append "_v1" to imgfiles's basename to avoid overwriting
  if origfile and File.exist?(imgpath) and File.exist?(destpath) and File.size(imgpath) != File.size(destpath)
    destpath.sub!(/\.([^.]*)$/, '_v1.\1')
  end
  File.directory?(destdir) || FileUtils.mkpath(destdir)
  if File.exist?(imgpath)     # duplicate file names in one Event are allowed in iPhoto
    $known[imgpath] = true
    ver = 2
    while File.exist?(destpath)
      destpath.sub!(/(_v[0-9]+)?\.([^.]*)$/, "_v#{ver}.\\2")
      ver += 1
    end
    FileUtils.ln(imgpath, destpath)
  else
    $missing.puts(imgpath) unless imgpath =~ /iLifeAssetManagement/
    $problems = true
  end
  # Work out the XMP sidecar location
  # Without extension: File.dirname(destpath) + '/' + File.basename(destpath, File.extname(destpath)) + ".xmp"
  # With extension:
  ["#{destpath}.xmp", destpath.sub(/^#{outdir}\//, '')]
end


# iPhoto internally stores times as integer values starting count at 2001-01-01. 
# Correct to be able to use parsed date values.
# Returns "YYYY-MM-DDTHH:MM:SS+NNNN" RFC 3339 string for XMP file.
def parse_date(intdate, tz_str="", strf=nil, deduct_tz=false)
  return '' unless intdate
  diff = Time.parse("2001-01-01 #{tz_str}")
  t = Time.at(intdate + diff.to_i).to_time
  # Apple saves DST times differently so Ruby is off by 1h during DST. Correct here.
  t2 = if t.dst? ; t - (60*60) else t end
  if deduct_tz
    t2 += Time.new.utc_offset
    unless t.dst?; t2 -= 3600 ; end
  end
  #debug 1, "  .. Time: #{t}, #{t2}, dst=#{t.dst?}, int=#{intdate}, tz=#{tz_str}, deduct=#{deduct_tz}, offset=#{Time.zone_offset(tz_str)}"
  strf ? t2.strftime(strf) : t2
end


# Debugging aid. Search for matching dates in metadata.
def date_compare(label, var, matches)
  stats = {}
  str1 = "  #{label.ljust(30)}: #{var}"
  str2 = ""
  ['taken', 'edited', 'imported'].each {|k|
    off = (var.to_i - matches[k].to_i)
    if var.to_i == matches[k].to_i
      str2 += " = #{k}, ".green
      stats[k] = 1
    elsif off.abs <= 60         # off by less than 10 seconds
      str2 += " ~ #{k} (off #{off}s), ".yellow.bold
    elsif off.abs <= 2*60*60    # off by max. 2 hours
      str2 += " ~ #{k} (off #{off}s), ".yellow
    end
  }
  str1 = str1.red unless str2
  debug 1, "#{str1}, #{str2}", true
  stats
end


# convert pure decimal GPS string with what=="LAT"/"LNG", e.g. format_gps("53.107295", "LAT") -> "53,"
def format_gps(latlng, what)
  return "" unless latlng and what
  whole = latlng.floor
  frac = latlng - whole
  #puts "#{whole}, #{frac}"
  dir = what.downcase=='lat' ? 'N' : 'E'
  sprintf '%i,%.6f%s', whole, frac*60, dir
end


# Calculate face rectangles for modified images. Much simpler since RKVersionFaceContent already contains converted rectangles.
# Note that modfaces Y values seem to be conunted from the *bottom*!
def calc_faces_edit(faces)
  res = faces.collect do |face|
    topleftx = face['topLeftX']
    toplefty = face['topLeftY']
    width    = face['width']
    height   = face['height']
    centerx  = topleftx + width/2
    centery  = toplefty + height/2
    {'mode' => 'FaceEdit ',
      'topleftx' => topleftx, 'toplefty' => toplefty,
      'centerx'  => centerx, 'centery' => centery, 'width' => width, 'height' => height,
      'name' => "#{face['name']} [mod]", 'email' => face['email'] }
  end
  res.each {|f|
    debug 3, sprintf("  ... %s: tl: %.6f %.6f, wh: %.6f %.6f;\t%s",
              f['mode'], f['topleftx'], f['toplefty'], f['width'], f['height'], f['name']).grey, true
    #debug 3, "  ... #{f['mode']}: tl: #{f['topleftx']} #{f['toplefty']}, wh: #{f['width']} #{f['height']};\t#{f['name']}".grey, true
  }
  res
end


# Calculate face position depending on rotation status and file type (special treatment for RW2).
def calc_faces(faces, frot=0, raw_factor_x=1, raw_factor_y=1)
  res = faces.collect do |face|
    width    = (raw_factor_x * case frot
      when 0 then   (face['bottomRightX'] - face['topLeftX']).abs
      when 90 then  (face['bottomRightX'] - face['topLeftX']).abs
      when 180 then (face['bottomRightX'] - face['topLeftX']).abs
      when 270 then (face['bottomRightX'] - face['topLeftX']).abs      # Verified OK
    end)

    height   = (raw_factor_y * case frot
      when 0 then   (face['bottomRightY'] - face['topLeftY']).abs
      when 90 then  (face['bottomRightY'] - face['topLeftY']).abs
      when 180 then (face['bottomRightY'] - face['topLeftY']).abs
      when 270 then (face['bottomRightY'] - face['topLeftY']).abs      # Verified OK
    end)

    topleftx = (raw_factor_x * case frot
      when 0 then    face['topLeftX']
      when 90 then   face['bottomRightX'] - width
      when 180 then  1 - face['bottomRightX'] - width
      when 270 then  1 - face['topLeftX']                              # Corrected
    end)

    toplefty = (raw_factor_y * case frot
      when 0 then   face['topLeftY']
      when 90  then 1 - face['bottomRightY'] - height
      when 180 then 1 - face['bottomRightY'] - height
      when 270 then 1 - face['topLeftY']                               # Corrected
    end)

    centerx  = (topleftx * raw_factor_x + width/2)
    centery  = (toplefty * raw_factor_y + height/2)
    mode = raw_factor_x==1 ? face['mode'] : 'FaceRaw '
    {'mode' => mode,
     'topleftx' => topleftx, 'toplefty' => toplefty,
     'centerx'  => centerx, 'centery' => centery, 'width' => width, 'height' => height,
     'name' => "#{face['name']} [#{mode||frot}]" || 'Unknown', 'email' => face['email'] }
  end
  res.each {|f|
    str = f['mode'] || "Face#{frot}°"
    debug 3, sprintf("  ... %s: tl: %.6f %.6f, wh: %.6f %.6f;\t%s",
      str, f['topleftx'], f['toplefty'], f['width'], f['height'], f['name']).grey, true
    #debug 3, "  ... #{str}: tl: #{f['topleftx']} #{f['toplefty']}, wh: #{f['width']} #{f['height']};\t#{f['name']}".grey, true
  }
  res
end


# Face debugging notes:
## Unflipped images seem to be ok.
##   0° flipped:  use FaceEdit face rectangles, e.g. 20070120155408, 20070120155646,
##  90° flipped:  flip on
## 180° flipped:  flip on left edge and in vertical center, e.g. 20150829_084621, 20150829_084522, 20150829_084520, most smartphone images


###################################################################################################
# Stage 1: Get main image info.
# Cannot use AlbumData.xml because a lot of info is not listed at all in AlbumData.xml but should be exported.
# Examples: keywords, hidden photos, trashcan, location *names*, ...
###################################################################################################
puts "Reading iPhoto database ..." unless ENV['DEBUG']
debug 1, 'Phase 1: Reading iPhoto SQLite data (Records: Library '.bold, false
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
        ,f.minImageDate AS roll_min_image_date          -- will be written to SQL script to optionally update digikam4.db
        ,f.maxImageDate AS roll_max_image_date
        ,f.minImageTimeZoneName AS roll_min_image_tz
        ,f.maxImageTimeZoneName AS roll_max_image_tz
        ,f.posterVersionUuid AS poster_version_uuid     -- event thumbnail image uuid
        ,f.createDate AS date_foldercreation            -- is this the 'imported as' date?
        ,v.uuid AS uuid
        ,m.uuid AS master_uuid        -- master (unedited) image. Required for face rectangle conversion.
        ,v.versionNumber AS version_number  -- 1 if edited image, 0 if original image
        ,v.mainRating AS rating       -- TODO: Rating is always applied to the master image, not the edited one
        ,m.type AS mediatype          -- IMGT, VIDT
        ,m.imagePath AS imagepath     -- 2015/04/27/20150427-123456/FOO.RW2, yields Masters/$imagepath and
                                      -- Previews: either Previews/$imagepath/ or dirname($imagepath)/$uuid/basename($imagepath)
     -- ,v.createDate AS date_imported
        ,m.createDate AS date_imported
        ,v.imageDate AS date_taken
     -- ,m.imageDate AS datem
        ,v.exportImageChangeDate AS date_modified
     -- ,m.fileCreationDate AS date_filecreation -- is this the 'date imported'? No
     -- ,m.fileModificationDate AS date_filemod
     -- ,replace(i.name, ' @ ', 'T') AS date_importgroup -- contains datestamp of import procedure for a group of files,
                                                    -- but this is apparently incorrect for images before 2012 -> ignore
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
        ,v.faceDetectionRotationFromMaster AS face_rotation      -- don't know, maybe a hint for face detection algorithm
        ,v.rotation AS rotation                 -- was the original image rotated?
   FROM RKVersion v
    LEFT JOIN RKFolder f ON v.projectUuid=f.uuid
    LEFT JOIN RKMaster m ON m.uuid = v.masterUuid
    LEFT JOIN RKImportGroup i ON m.importGroupUuid = i.uuid
 ")
debug 1, "#{masters.count}; ", false


propertydb = SQLite3::Database.new("#{iphotodir}/Database/apdb/Properties.apdb")
propertydb.results_as_hash = true
placehead, *places = propertydb.execute2('SELECT
  p.modelId, p.uuid, p.defaultName, p.minLatitude, p.minLongitude, p.maxLatitude, p.maxLongitude, p.centroid, p.userDefined
  FROM RKPlace p');
# placehead, *places = propertydb.execute2("SELECT p.modelId, p.uuid, p.defaultName, p.minLatitude, p.minLongitude, p.maxLatitude, p.maxLongitude, p.centroid, p.userDefined, n.language, n.description FROM RKPlace p INNER JOIN RKPlaceName n ON p.modelId=n.placeId");
placelist = places.inject({}) {|h,place| h[place['modelId']] = place; h }
debug 1, "Properties (#{places.count} places; ", false

# Get description text of all photos.
deschead, *descs = propertydb.execute2("SELECT
  i.modelId AS id, i.versionId AS versionId, i.modDate AS modDate, s.stringProperty AS string
FROM RKIptcProperty i LEFT JOIN RKUniqueString s ON i.stringId=s.modelId
WHERE i.propertyKey = 'Caption/Abstract' ORDER BY versionId")
photodescs = descs.inject({}) {|h,desc| h[desc['versionId']] = desc['string']; h }
# FYI: this is the date of adding the description, not the last photo edit date
photomoddates = descs.inject({}) {|h,desc| h[desc['versionId']] = desc['modDate']; h }
debug 1, "Description #{descs.count}; ", false

facedb = SQLite3::Database.new("#{iphotodir}/Database/apdb/Faces.db")
facedb.results_as_hash = true

# Get list of names to associate with modified face rectangle list (which does not contain this info).
fnamehead, *fnames = facedb.execute2('SELECT modelId ,uuid ,faceKey ,name ,email FROM RKFaceName')
fnamelist = fnames.inject({}) {|h,fname| h[fname['faceKey'].to_i] = fname; h }
debug 1, "Faces #{fnamelist.size}; ", false

# Get list of Event notes (pre-iPhoto 9.1) and save to text file. There is no XMP standard for this data.
notehead, *notes = librarydb.execute2("SELECT RKNote.note AS note, RKFolder.name AS name
  FROM RKNote LEFT JOIN RKFolder on RKNote.attachedToUuid = RKFolder.uuid
  WHERE RKFolder.name IS NOT NULL AND RKFolder.name != '' ORDER BY RKFolder.modelId")
File.open("#{outdir}/event_notes.sql", 'w') do |f|
  notes.each do |note|
    f.puts("UPDATE Albums SET caption='#{note['note'].sqlclean}' WHERE relativePath LIKE '%/#{note['name'].sqlclean}';")
  end
end unless notes.empty?
debug 1, "Event Notes #{notes.size}).", true


# Get Folders and Albums. Convert to (hierarchical) keywords since "Albums" are nothing but tag collections.
# Also get search criteria for "smart albums". Save into text file (for lack of better solution).
# 1. Get folder structure, create tag pathnames as strings.
#    Folders are just a pseudo hierarchy and can contain Albums and Smart Albums.
folderhead, *folderdata = librarydb.execute2(
    'SELECT modelId, uuid, folderType, name, parentFolderUuid, folderPath
     FROM RKFolder
     WHERE -- isMagic=0 AND   -- Magic=1 folders are iPhoto internal like Trash, Library etc. but we need these for the path
       folderType=1           -- folderType=2 are Events. We handle those as filesystem directories.
  ')
# folderPath is a string like "modelId1/modelId2/...". Convert these using the real folder names to get the path strings.
folderlist  = folderdata.inject({}) {|h,folder| h[folder['modelId'].to_i] = folder; h }
foldernames = folderdata.inject({}) {|h,folder| h[folder['modelId'].to_s] = folder['name']; h }
folderlist.each {|k,v| folderlist[k]['folderPath'].gsub!(/\d*/, foldernames).gsub!(/^\/(.*)\/$/, '\1') }
debug 3, "foldernames: " + foldernames.inspect.grey, true
debug 3, "folderlist: " + folderlist.collect{|k,v| v['folderPath']}.join(', ').grey, true


# Export album metadata (mostly binary PLists) but so far nothing is done with it except save it.
albumhead, *albumdata = librarydb.execute2(
 "SELECT modelId, uuid, name, folderUuid, filterData, queryData, viewData
    FROM RKAlbum
   WHERE albumSubclass = 2
     AND uuid NOT LIKE '%Album%'")
albumqdir = "#{outdir}/00_AlbumQueryData"
File.directory?(albumqdir) || Dir.mkdir(albumqdir)
debug 3, "Albumdata: " + albumdata.collect{|a| a['name'] }.join(', ').grey, true
albumdata.each do |d|
  next if !d['name'] or d['name'] == ''
  ['filterData', 'queryData', 'viewData'].each do |datakey|
    next if d[datakey].nil?
    albumqname = d['name'].gsub(/[<>|\/;:\*\"]/, '-')
    File.open("#{albumqdir}/#{albumqname}.#{datakey}", 'w') do |j|
      PP.pp(CFPropertyList.native_types(CFPropertyList::List.new(data: d[datakey]).value), j)
    end
  end
end


orienthead, *orientdata = propertydb.execute2("
  SELECT O.versionId v_id, S.stringProperty str FROM RKOtherProperty O
  LEFT JOIN RKUniqueString S ON S.modelId=O.stringId WHERE O.propertyKey='Orientation'")
#orientlist = orientdata.inject({}) { |h,orient| h[orient['v_id'].to_s] = orient['str'] }
#debug 3, "Orientations: " + orientdata.inspect.grey, true

curr_roll = nil

###################################################################################################
# Stage 2: Big loop through all photos
###################################################################################################
basedir = iphotodir
debug 1, "Phase 2/3: Exporting iPhoto archive\n  from #{basedir}\n  to   #{outdir}".bold, true
bar = ProgressBar.create(title: 'Exporting', total: masters.length) unless ENV['DEBUG']   # only if DEBUG isn't set

$missing = File.open("#{outdir}/missing.log", 'w')
$problems = false
$known = Hash.new
done_xmp = Hash.new
xmp_template = File.read("#{File.expand_path(File.dirname(__FILE__))}/iphoto2xmp_template.xmp.erb")

eventmetafile = File.open("#{outdir}/event_metadata.sql", 'w')
group_mod_data = []

face_csv_list = []

# iPhoto almost always stores a second version (Preview) of every image. In my case, out of 41000 images
# only four had just a single version and one had six versions (print projects). So we can safely assume
# one 'original' and one 'modified' version exist of each image and just loop through the master images.
masters.each do |photo|
  bar.increment unless ENV['DEBUG']

  if resume = ENV['RESUME'].to_i and resume > 0
    next if resume >= photo['id'].to_i
    if resume == photo['id'].to_i
      debug 1, "Resuming at RKVersion id #{resume}.".bold, true
      debug 1, "WARNING: this will create incomplete postmortem SQL scripts.\nDon't use this if you need them. See README.md for details.".red.bold, true
    end
  end

  # Debugging to export a single image (or all images matching a certain regexp)
  if caption = ENV['CAPTION']
    next unless photo['caption'] =~ /#{caption.gsub(/,/, '|')}/i       # caption can e.g. be 'IMG_1,IMG_2,...'
  end

  origpath = "Masters/#{photo['imagepath']}"

  # $known doesn't work here, various info in RKVersion is different (eg. caption)
  next if $known["#{basedir}/#{origpath}"]
  # Preview can be mp4, mov, jpg, whatever - but not RAW/RW2, it seems.
  # Preview has jpg or JPG extension. Try both.
  # Preview can be in one of two directory structures (depending on iPhoto version). Try both.
  modpath1 = "Previews/#{photo['imagepath']}"
  modpath2 = "Previews/#{File.dirname(photo['imagepath'])}/#{photo['uuid']}/#{File.basename(photo['imagepath']).gsub(/PNG$|JPG$|RW2$/, 'jpg')}"
  modpath = File.exist?("#{basedir}/#{modpath1}") ? modpath1 : modpath2
  if photo['mediatype'] != 'VIDT' and !File.exist?("#{basedir}/#{modpath}")
    modpath = modpath.sub(/jpg$/, 'JPG')
  end
  origxmppath, origdestpath = link_photo(basedir, outdir, photo, origpath, nil)
  next if done_xmp[origxmppath]    # do not overwrite master XMP twice
  # link_photo needs origpath to do size comparison for modified images
  # only perform link_photo for "non-videos" and when a modified image should exist
  # since iPhoto creates "link mp4" files without real video content for "modified" videos (useless)
  if photo['version_number'].to_i > 0 and photo['mediatype'] != 'VIDT'
    modxmppath, moddestpath = link_photo(basedir, outdir, photo, modpath, origpath)
  end

  # FIXME: Fix size of RW2 files (incorrectly set to 3776x2520, but Digikam sees 3792x2538) (Panasonic LX3)
  # TODO: Get real size of RW2 files (dcraw -i -v $FILE | grep "Image Size" | ...) and use that
  if photo['imagepath'] =~ /RW2$/ and photo['master_height'].to_i == 2520
    photo['raw_factor_h'] = 2538.0 / photo['master_height'].to_f   # for converting face positions
    photo['raw_factor_w'] = photo['raw_factor_h'] * 2.0 - 1        # don't ask me. It's not "3792.0 / photo["master_width"].to_f".
    #photo["raw_factor_h"] = 1.01
    #photo["raw_factor_w"] = 1.01
    photo['master_height'] = 2538    # incorrect. iPhoto always uses its own internal (wrong) sizes for crop calculations
    photo['master_width'] = 3792
  else
    photo['raw_factor_h'] = 1               # Dummy
    photo['raw_factor_w'] = 1
  end


  # Collect roll/event metadata and write SQL scripts to update Digikam db after import.
  # This data is not image specific but album/roll specific and thus cannot be written to XMP.
  if photo['uuid'] == photo['poster_version_uuid']
    subsearch = sprintf("SELECT i.id FROM Images i LEFT JOIN Albums a ON i.album=a.id
      LEFT JOIN ImageComments c ON c.imageid=i.id WHERE c.comment='%s' AND a.relativePath LIKE '%%/%s' LIMIT 1",
                      photo['caption'].sqlclean, photo['rollname'].sqlclean)
    eventmetafile.printf("UPDATE Albums SET date='%s', icon=(%s) WHERE relativePath LIKE '%%/%s';\n",
           parse_date(photo['roll_min_image_date'], photo['timezone'], '%Y-%m-%d'), subsearch, photo['rollname'].sqlclean)
  end


  # Group modified and original images just like in iPhoto.
  # Images have to be identified by (possibly modified) filename and album path since the XMP UUID is not kept
  if modxmppath
    origsub = sprintf("SELECT i.id FROM Images i LEFT JOIN Albums a ON i.album=a.id WHERE i.name='%s' AND a.relativePath LIKE '%%/%s'", File.basename(origxmppath, '.*').sqlclean, photo['rollname'].sqlclean)
    mod_sub = sprintf("SELECT i.id FROM Images i LEFT JOIN Albums a ON i.album=a.id WHERE i.name='%s' AND a.relativePath LIKE '%%/%s'", File.basename(modxmppath, '.*').sqlclean, photo['rollname'].sqlclean)
    # last parameter: 1 = versioned groups,  2 = normal groups. Here we want 1.
    group_mod_data << sprintf("((%s), (%s), 1)", mod_sub, origsub)
    # noinspection RubyScope
    group_mod_data << sprintf("((%s), (%s), 2)", origsub, mod_sub)
  end


  if curr_roll != photo['rollname']
    # write debug output if required
    if p = photo['poster_version_uuid']
      debug 1, "\nEVENT: #{photo['rollname']} (thumb: #{p[0..6]}…): #{parse_date(photo['roll_min_image_date'], photo['timezone'], '%Y-%m-%d')} .. #{parse_date(photo['roll_max_image_date'], photo['timezone'], '%Y-%m-%d')}".bold, true
    else
      debug 1, "\nEVENT: #{photo['rollname'] || "(NO ROLL NAME)"} (?)".bold, true
    end
    curr_roll = photo['rollname']
  end
  @date_taken = parse_date(photo['date_taken'], photo['timezone'])
  @date_modified = parse_date(photo['date_modified'], photo['timezone'])
  @date_imported = parse_date(photo['date_imported'], photo['timezone'])
  datestr = "taken:#{@date_taken.strftime("%Y%m%d-%H%M%S%z") rescue "MISSING".red} edit:#{@date_modified.strftime("%Y%m%d-%H%M%S%z") rescue "MISSING".red} import:#{@date_imported.strftime("%Y%m%d-%H%M%S%z") rescue "MISSING".red}"
  str = " #{photo['id']}(#{photo['master_id']}): #{File.basename(photo['imagepath'])}\t#{photo['caption']}\t#{photo['rating']}* #{photo['uuid'][0..5]}…/#{photo['master_uuid'][0..5]}…\t#{datestr}\t#{p=placelist[photo['place_id']] ? "Loc:#{p}" : ""}"
  debug 1, (ENV['DEBUG'].to_i > 1 ? str.bold : str), true
  debug 2, "  Desc: #{photodescs[photo['id'].to_i]}".green, true  if photodescs[photo['id'].to_i]
  debug 2, "  Orig: #{photo['master_height']}x#{photo['master_width']} (#{'%.4f' % photo['raw_factor_h']}/#{'%.4f' % photo['raw_factor_w']}), #{origpath} (#{File.exist?("#{basedir}/#{origpath}") ? 'found'.green : 'missing'.red})", true
  debug 3, "     => #{origdestpath}".cyan, true
  if photo['face_rotation'].to_i != 0 or photo['rotation'] != 0
    debug 2, "  Flip: photo #{photo['rotation']}°, face(s): #{photo['face_rotation']}°".blue, true
  end
  # Test for modified images.
  #debug 2, "  Mod1: #{modpath1}, Dir:", false
  #debug 2, Dir.exist?(File.dirname("#{basedir}/#{modpath1}")) ? 'OK'.green : 'missing'.red, false
  #debug 2, File.exist?("#{basedir}/#{modpath1}") ? ', file OK'.green : ', file missing'.red, true
  #debug 2, "  Mod2: #{modpath2} ", false
  #debug 2, Dir.exist?(File.dirname("#{basedir}/#{modpath2}")) ? 'OK'.green : 'missing'.red, false
  #debug 2, File.exist?("#{basedir}/#{modpath2}") ? ', file OK'.green : ', file missing'.red, true
  if modxmppath    # modified version *should* exist
    debug 2, "  Mod : #{photo['processed_height']}x#{photo['processed_width']}, #{modpath} ", false
    debug 2, File.exist?("#{basedir}/#{modpath}") ? '(found)'.green : '(missing)'.red, true
    debug 2, "     => #{moddestpath}".cyan, true  if File.exist?("#{basedir}/#{modpath}")
  end

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
  @date_meta = parse_date(photomoddates[photo['id']], photo['timezone'])

  # save GPS location info in XMP file (RKVersion::overridePlaceId -> Properties::RKPlace
  #       (user boundaryData?)
  # TODO: use Library::RKPlaceForVersion to get named Places for photo Versions
  @longitude = format_gps(photo['longitude'], 'lng')
  @latitude  = format_gps(photo['latitude'], 'lat')
  if p = placelist[photo['place_id']]
    #@gpscity = ''
    #@gpsstate = ''
    #@gpscountryname = ''
    @gpslocation = p['defaultName']
    #@gps3lettercountrycode = ''
  else
    @gpslocation = nil
  end
  debug 2, "  GPS : lat:#{@latitude} lng:#{@longitude}, #{@gpslocation}".violet, true


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
  @keylist << 'iPhoto/Hidden' if photo['hidden']==1
  @keylist << 'iPhoto/Flagged' if photo['flagged']==1
  @keylist << 'iPhoto/Original' if photo['original']==1
  @keylist << 'iPhoto/inTrash' if photo['in_trash']==1
  debug 2, "  Tags: #{photokw.collect {|k| "#{k['name']}(#{k['modelId']})" }.join(', ')}".blue, true unless photokw.empty?


  # For each photo, get list of albums where this photo is contained. Recreate folder/album hierarchy as tags.
  albumhead, *albumdata = librarydb.execute2(
   "SELECT av.modelId, av.versionId, av.albumId, a.name, f.modelId AS f_id, f.uuid AS f_uuid
      FROM RKAlbumVersion av LEFT JOIN RKAlbum a ON av.albumId=a.modelId
                             LEFT JOIN RKFolder f ON f.uuid=a.folderUuid
     WHERE av.versionId=#{photo['id'].to_i}")
  albumlist  = albumdata.uniq.inject({}) {|h,album|
    h[album['modelId'].to_i] = album
    h[album['modelId'].to_i]['path'] = "#{folderlist[album['f_id']]['folderPath']}/#{album['name']}"
    h
  }
  albums = albumlist.collect{|k,v| v['path']}.uniq
  debug 2, "  AlbumTags: #{albums}".blue, true unless albums.empty?
  @keylist += albums

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
  # TODO: Use History.apdb::RKImageAdjustmentChange table to fill edit operations.
 

  # If photo was edited, check if dimensions were changed (crop, rotate, iOS edit)
  # since this would require recalculation of the face rectangle locations.
  # Unfortunately, the crop info is saved in a PropertyList blob within the 'data' column of the DB.
  # Can it be more cryptic please? Who designs this crap anyway?
  crop_startx = crop_starty = crop_width = crop_height = crop_rotation_factor = 0
  if photo['version_number'].to_i > 0
    debug 3, "  Edit:  #{edits.collect{|e| e['adj_name'] }.join(",").gsub(/RK|Operation/, '')}", true
    edits.each do |edit|
      check = false
      edit_plist_hash = CFPropertyList.native_types(CFPropertyList::List.new(data: edit['data']).value)
      # save raw PropertyList data in additional sidecar file for later analysis
      File.open(modxmppath.gsub(/xmp/, "plist_#{edit['adj_name']}"), 'w') do |j|
        PP.pp(edit_plist_hash, j)
      end

      # NB: Not needed any more for face positioning since Library::RKVersionFaceContent was found.
      case edit['adj_name'] 
        when 'RKCropOperation'
          check = edit_plist_hash['$objects'][13] == 'inputRotation'
          # eg. 1612, 2109, 67, 1941 - crop positions
          # actually, these are dynamic - the PList hash must be analyzed in depth to get positions.
          crop_startx = edit_plist_hash['$objects'][20]    # xstart: position from the left
          crop_starty = edit_plist_hash['$objects'][23]    # ystart: position from the bottom!
          crop_width  = edit_plist_hash['$objects'][22]    # xsize:  size in pixels from xstart
          crop_height = edit_plist_hash['$objects'][24]    # ysize:  size in pixels from ystart
          debug 3, "Crop (#{crop_startx}x#{crop_starty}+#{crop_width}+#{crop_height}), ", false
        when 'RKStraightenCropOperation'
          check = edit_plist_hash['$objects'][9] == 'inputRotation'
          # factor examples: 1.04125 ~ 1.0° ; -19.0507 ~ -19,1°
          crop_rotation_factor = edit_plist_hash['$objects'][10]    # inputRotation in ° (degrees of 360°)
          debug 3, "StraightenCrop (#{crop_rotation_factor}), ", false
        when 'DGiOSEditsoperation'
          # TODO: image was edited in iOS which creates its own XMP file (with proprietary aas and crs tags).
          debug 3, 'iOSEdits (???), ', false
        else
          # No region adjustment required for RawDecode, Whitebalance, ShadowHighlight, Exposure, NoiseReduction,
          # ProSharopen, iPhotoRedEye, Retouch, iPhotoEffects, and possibly others
      end
    end # edits.each
    debug 3, '', true if edits.count > 0
  end


  #
  # Add faces to BOTH original and edited images.
  # If edited image is cropped, modify face rectangle positions accordingly.
  xmp_mod = xmp.dup

  # Link: Faces.apdb::RKDetectedFace::masterUuid == Library.apdb::RKMaster::uuid
  facehead, *faces = facedb.execute2(
      "SELECT d.modelId               -- primary key
         ,d.uuid AS detect_uuid       -- primary key
         ,d.masterUuid                -- --> Library::RKMaster::uuid
         ,d.faceKey AS face_key       -- --> RKFaceName::faceKey
          -- *relative* coordinates within *original, non-rotated* image (0..1)
          -- Y values are counted from the bottom in iPhoto, but X values are counted from the left like usual!
         ,d.topLeftX    ,1-d.topLeftY    AS topLeftY   ,d.topRightX    ,1-d.topRightY    AS topRightY
         ,d.bottomLeftX ,1-d.bottomLeftY AS bottomLeftY,d.bottomRightX ,1-d.bottomRightY AS bottomRightY
         ,abs(d.topLeftX - d.bottomRightX) AS width
         ,abs(d.topLeftY - d.bottomRightY) AS height
         ,d.width           AS image_width          -- TODO: check whether face was meant to be rotated?
         ,d.height          AS image_height
         ,d.faceDirectionAngle  AS face_dir_angle
         ,d.faceAngle           AS face_angle      -- always 0?
         ,d.confidence
         ,d.rejected
         ,d.ignore
         ,n.uuid AS name_uuid
         ,n.name AS name          -- more reliable, also seems to contain manually added names
         ,n.fullName AS full_name -- might be empty if person is not listed in user's address book
         ,n.email AS email
      FROM RKDetectedFace d
      LEFT JOIN RKFaceName n ON n.faceKey=d.faceKey
      WHERE d.masterUuid='#{photo['master_uuid']}'
      ORDER BY d.modelId")  # LEFT JOIN because we also want unknown faces

  ## face debugging photos:
  ## 20070120155408,20070120155646,20070120155919,20070120160320,1980-08_07,0802_IMG,DSCF4947,dscf1828,dscf1833,DSCF2239,DSCF2240,DSCF4948,DSCF4948,20150103_093106,20150110_220459,20150609_120655,20150111,181534,20150829_084621,P1010287,IMG_1707
  ## Criteria:
  ## - multiple faces
  ## - edited
  ## - flipped 90°, 180°, 270°
  ## - cropped   - e.g. 20150609_120655
  ## -

  # Get face rectangles from modified images (cropped, rotated, etc). No need to calculate those manually.
  # This might be empty, in that case use list of unmodified faces.
  modfacehead, *modfaces = librarydb.execute2(
    "SELECT d.modelId        AS id
           ,d.versionId      AS version_id
           ,d.masterId       AS master_id
           ,d.faceKey        AS face_key
           ,d.faceRectLeft   AS topLeftX      -- use same naming scheme as in 'faces'
         ,1-d.faceRectTop    AS bottomRightY  -- Y values are counted from the bottom in this table!
           ,d.faceRectWidth  AS width
           ,d.faceRectHeight AS height
           ,d.faceRectWidth + d.faceRectLeft      AS bottomRightX
         ,1-d.faceRectTop   - d.faceRectHeight    AS topLeftY
     FROM RKVersionFaceContent d
     WHERE d.versionId = '#{photo['id']}'
     ORDER BY d.versionId")

  facekeys = modfaces.collect {|v| v['face_key'] }
  modfaces_ = modfaces.collect { |v|
     v.update({'mode' => 'FaceEdit',
               'name' => (fnamelist[v['face_key'].to_i]['name'] rescue ''),
               'email' => (fnamelist[v['face_key'].to_i]['email'] rescue '')})
  }

  debug 3, "  ... Original Face DB data:", true
  faces.each do |face|
    debug 3, sprintf("  ...     face: tl: %.6f %.6f, wh: %.6f %.6f,  %s  (%i)",
      face['topLeftX'], face['topLeftY'], face['width'], face['height'], face['name'], face['face_key']).grey, true
  end
  modfaces_.each do |face|
    debug 3, sprintf("  ...  modface: tl: %.6f %.6f, wh: %.6f %.6f,  %s  (%i)",
      face['topLeftX'], face['topLeftY'], face['width'], face['height'], face['name'], face['face_key']).grey, true
  end

  # Debug to check for matches: For each face, output CSV. Format see after main loop.
  face_csv_list << facekeys.collect do |fn|
    oface = faces.find {|f| f['face_key'] == fn }#  ; puts oface.inspect
    mface = modfaces_.find {|f| f['face_key'] == fn }#  ; puts mface.inspect
    sprintf("%s,%s,%s,%s,%s,%s,%s,%s,%s,%.6f,%.6f,%.6f,%.6f,%.6f,%.6f,%.6f,%.6f",
      photo['id'].to_s, photo['caption'], photo['rotation'].to_s, photo['face_rotation'].to_s, oface['face_angle'].to_s, oface['face_dir_angle'].to_s, '', mface['name'], fn,
        oface['topLeftX'], oface['topLeftY'], oface['width'], oface['height'],
        mface['topLeftX'], mface['topLeftY'], mface['width'], mface['height']
       )
  end

  # calc_faces(faces, rotation, raw_factor_x=1, raw_factor_y=1)
  # Flipped images (90°, 180°, 270° by RKVersion.rotation) need to have their orig_faces flipped as well and do not need modfaces.
  # ... for flipped images, modfaces might contain incorrect face data!
  # StraightenCrop and/or Crop needs modfaces.
  debug 3, "  ... After processing:", true
  width = photo['master_width'].to_i
  height = photo['master_height'].to_i
  @orig_faces = calc_faces(faces,  photo['rotation'].to_i)
#  @orig_faces = calc_faces(faces)
  @rw2_faces  = calc_faces(faces, photo['rotation'].to_i, photo['raw_factor_w'] || 1, photo['raw_factor_h'] || 1)
  @crop_faces = calc_faces_edit(modfaces_)

  # TODO: additionally specify modified image as second version of original file in XMP (DerivedFrom?)
  unless(File.exist?(origxmppath))         # don't overwrite existing XMP - right now, kind of pointless but anyway
    if photo['imagepath'] =~ /RW2$/
      @faces = @rw2_faces
      @facecomment = "Using [raw] hacked RAW face rectangles"
    else
      @faces = @orig_faces
      @facecomment = "Using [orig] RKDetectedFace, RKFaceName"
    end
    j = File.open(origxmppath, 'w')
    j.puts(ERB.new(xmp, 0, '>').result)
    j.close
    done_xmp[origxmppath] = true
  end
  if photo['version_number'].to_i == 1 and modxmppath and !File.exist?(modxmppath)
    if @crop_faces.empty?
      @faces = @orig_faces
      @facecomment = "Using [orig] RKDetectedFace, RKFaceName"
    else
      @faces = @crop_faces
      @facecomment = "Using [edit] RKVersionFaceRectangles"
    end
    @uuid = photo['uuid']             # for this image, use modified image's uuid
    j = File.open(modxmppath,  'w')
    j.puts(ERB.new(xmp_mod, 0, '>').result)
    j.close
  end

  debug 3, '', true

end

eventmetafile.close

unless face_csv_list.empty?
  debug 3, "vers_id,caption,rotation,face_rotation,face_angle,face_dir_angle,visible_rot,face_name,face_key,face_tlx,face_tly,face_w,face_h,modface_tlx,modface_tly,modface_w,modface_h", true
  debug 3, face_csv_list.flatten.join("\n")
end

exit if ENV['CAPTION']

# Write grouping information to SQL file for Digikam.
# Group data into blocks of 1000 inserts otherwise sqlite will barf.
group_mod_file = File.open("#{outdir}/group_modified.sql", 'w') do |f|
  group_mod_data.each_slice(100) {|batch|
    f.printf("INSERT OR REPLACE INTO ImageRelations (subject, object, type) VALUES %s ;", batch.join(",\n"))
    f.printf("\n\n");
  }
end


$missing.close
if $problems
  puts "\nOne or more files were missing from your iPhoto library! See 'missing.log' in output directory."
  debug 2, File.read("#{outdir}/missing.log"), true
else
  File.unlink("#{outdir}/missing.log")
end



###################################################################################################
# Stage 3: Search for orphans.
###################################################################################################
debug 1, "\n\nPhase 3/3: Searching for lost masters", true

Find.find("#{iphotodir}/Masters").each do |file|
  ext = File.extname(file)
  if ext.match(/\.(PNG|BMP|RAW|RW2|CR2|CRW|TIF|DCR|DNG)/i)
    if !$known[file]
      imgfile = file.sub(/^#{iphotodir}\/Masters\//i,'')
      destfile = "#{outdir}/Lost and Found/#{imgfile}"
      destdir = File.dirname(destfile)
      FileUtils.mkpath(destdir) unless File.directory?(destdir)
      FileUtils.ln(file, destfile) unless File.exists?(destfile)
      debug 1, "  Found #{imgfile}", true
    end
  end
end

# vim:set ts=2 expandtab:
