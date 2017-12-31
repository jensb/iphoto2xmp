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
require 'exifr/jpeg'             # required to read orientation metadata from image files
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
    # FIXME: just for faces debugging
    #destpath = "#{outdir}/#{photo['rotation']}/#{File.basename(imgpath)}"
    year = parse_date(photo['roll_min_image_date'], photo['roll_min_image_tz'])
    if year
      destpath = "#{outdir}/#{year.strftime("%Y")}/#{photo['rollname']}/#{File.basename(imgpath)}"
    else
      destpath = "#{outdir}/#{photo['rollname']}/#{File.basename(imgpath)}"
    end
  else
    destpath = "#{outdir}/00_ImagesWithoutEvents/#{imgfile}"
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


# Convert EXIFR values into degrees for rotation.
def convert_exif_rot(val)
  return 0 if !val or val==''
  case val
    when 1 then 0
    when 8 then 270
    when 3 then 180
    when 6 then 90
    else 0
  end
end


# iPhoto internally stores times as integer values starting count at 2001-01-01. 
# Correct to be able to use parsed date values.
# Returns "YYYY-MM-DDTHH:MM:SS+NNNN" RFC 3339 string for XMP file.
def parse_date(intdate, tz_str="", strf=nil, deduct_tz=false)
  return nil unless intdate
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
    width    = raw_factor_x * (face['bottomRightX'] - face['topLeftX']).abs
    height   = raw_factor_y * (face['bottomRightY'] - face['topLeftY']).abs
    if frot==90 or frot==270 ; x = height ; height = width; width = x ; end

    #   0°: validated correct for all images
    #  90°: errors e.g. in 0802_img with orig_faces
    # 180°: validated correct for all images except IMG_1707
    # 270°: errors e.g. in 20150111_181534, 20150111_181614
    # Swapping 90/270° rotation factors does not improve matters with faces or modfaces values
    case frot.to_i
      when  90 then topleftx = 1 - face['topLeftY']             ; toplefty = face['topLeftX']
      when 180 then topleftx = 1 - face['topLeftX']             ; toplefty = 1 - face['topLeftY']
      when 270 then topleftx = face['topLeftY']                 ; toplefty = 1 - face['topLeftX']
      else          topleftx = face['topLeftX']                 ; toplefty = face['topLeftY']
    end
    centerx  = (topleftx * raw_factor_x + width/2)
    centery  = (toplefty * raw_factor_y + height/2)
    mode = raw_factor_x==1 ? face['mode'] : 'FaceRaw '
    [
      {'mode' => mode, 'topleftx' => topleftx, 'toplefty' => toplefty,
       'centerx'  => centerx, 'centery' => centery, 'width' => width, 'height' => height,
       'name' => "#{face['name']} [#{mode||frot}]" || 'Unknown', 'email' => face['email'] },
     # {'mode' => "#{mode}2", 'topleftx' => topleftx, 'toplefty' => toplefty,
     #  'centerx'  => centerx, 'centery' => centery, 'width' => width, 'height' => height,
     #  'name' => "#{face['name']} [#{mode||frot}]" || 'Unknown', 'email' => face['email'] },
    ]
  end
  res
  res = res.flatten
  res.each {|f|
    str = f['mode'] || "Face#{frot}°"
    debug 3, sprintf("  ... %s: tl: %.6f %.6f, wh: %.6f %.6f;\t%s",
      str, f['topleftx'], f['toplefty'], f['width'], f['height'], f['name']).grey, true
  }
  res
end


###################################################################################################
# Stage 1: Get main image info.
# Cannot use AlbumData.xml because a lot of info is not listed at all in AlbumData.xml but should be exported.
# Examples: keywords, hidden photos, trashcan, location *names*, ...
###################################################################################################
puts "Reading iPhoto database ..." unless ENV['DEBUG']
debug 1, 'Phase 1: Reading iPhoto SQLite data (Records: Library '.bold, false
librarydb = SQLite3::Database.new("#{iphotodir}/database/photos.db")
librarydb.results_as_hash = true  # gibt [{"modelId"=>1, "uuid"=>"SwX6W9...", "name"=>".."
#keyhead, *keywords = librarydb.execute2("SELECT modelId, uuid, name, shortcut FROM RKKeyword")
#puts "... Available Keywords: #{keywords.collect {|k| k['name'] }.join(", ")}"
#region SQL ...
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
        ,m.imagePath AS imagepath     -- 2015/04/27/20150427-123456/FOO.RW2, yields Masters/$imagepath and
                                      -- Previews: either Previews/$imagepath/ or dirname($imagepath)/$uuid/basename($imagepath)
     -- ,v.createDate AS date_imported
        ,m.createDate AS date_imported
        ,v.imageDate AS date_taken
     -- ,m.imageDate AS datem
        ,v.lastModifiedDate AS date_modified
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
    LEFT JOIN RKAlbumVersion av ON v.modelId=av.versionId
    LEFT JOIN RKAlbum a ON av.albumId=a.modelId
    LEFT JOIN RKFolder f ON a.folderUuid=f.uuid 
    LEFT JOIN RKMaster m ON m.uuid = v.masterUuid
    LEFT JOIN RKImportGroup i ON m.importGroupUuid = i.uuid
 ")
debug 1, "#{masters.count}; ", false

masters.select! { |photo| !!photo['roll'] }
debug 1, "#{masters.count}; ", false

#endregion

placehead, *places = librarydb.execute2('SELECT
  p.modelId, p.uuid, p.defaultName, p.minLatitude, p.minLongitude, p.maxLatitude, p.maxLongitude, p.centroid, p.userDefined
  FROM RKPlace p');
placelist = places.inject({}) {|h,place| h[place['modelId']] = place; h }
debug 1, "Properties (#{places.count} places; ", false

# Get description text of all photos.
deschead, *descs = librarydb.execute2("SELECT
  v.modelId AS id, v.uuid AS versionId, v.createDate AS modDate, v.extendedDescription AS string
FROM RKVersion v WHERE v.extendedDescription IS NOT NULL")
photodescs = descs.inject({}) {|h,desc| h[desc['versionId']] = desc['string']; h }
# FYI: this is the date of adding the description, not the last photo edit date
photomoddates = descs.inject({}) {|h,desc| h[desc['versionId']] = desc['modDate']; h }
debug 1, "Description #{descs.count}; ", false

# Get list of names to associate with modified face rectangle list (which does not contain this info).
fnamehead, *fnames = librarydb.execute2('SELECT modelId, uuid, name, displayName as email FROM RKPerson')
fnamelist = fnames.inject({}) {|h,fname| h[fname['faceKey'].to_i] = fname; h }
debug 1, "Faces #{fnamelist.size}; ", false


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
# TODO: save modified version only when original was "really" modified (EXIF rotate is not a real modification).
#       Otherwise save original image only since it is (often) smaller in file size.
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
  modpath1 = "Previews/#{photo['imagepath'].gsub(/PNG$|JPG$|RW2$/, 'JPG')}"
  # if photo['mediatype'] != 'VIDT' and !File.exist?("#{basedir}/#{modpath1}")
  if !File.exist?("#{basedir}/#{modpath1}")
    modpath1.gsub!(/jpg$/, 'JPG')
  end
  modpath2 = "Previews/#{File.dirname(photo['imagepath'])}/#{photo['uuid']}/#{File.basename(photo['imagepath']).gsub(/PNG$|JPG$|RW2$/, 'jpg')}"
  # if photo['mediatype'] != 'VIDT' and !File.exist?("#{basedir}/#{modpath2}")
  if !File.exist?("#{basedir}/#{modpath2}")
    modpath2 = modpath2.sub(/jpg$/, 'JPG')
  end
  modpath = File.exist?("#{basedir}/#{modpath1}") ? modpath1 : modpath2

  origxmppath, origdestpath = link_photo(basedir, outdir, photo, origpath, nil)
  next if done_xmp[origxmppath]    # do not overwrite master XMP twice
  # link_photo needs origpath to do size comparison for modified images
  # only perform link_photo for "non-videos" and when a modified image should exist
  # since iPhoto creates "link mp4" files without real video content for "modified" videos (useless)
  # if photo['version_number'].to_i > 0 and photo['mediatype'] != 'VIDT'
  if photo['version_number'].to_i > 0
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
  # Test for modified images.
  #debug 2, "  Mod1: #{modpath1}, Dir ", false
  #debug 2, Dir.exist?(File.dirname("#{basedir}/#{modpath1}")) ? 'OK'.green : 'missing'.red, false
  #debug 2, File.exist?("#{basedir}/#{modpath1}") ? ', file OK'.green : ', file missing'.red, true
  #debug 2, "  Mod2: #{modpath2}, Dir ", false
  #debug 2, Dir.exist?(File.dirname("#{basedir}/#{modpath2}")) ? 'OK'.green : 'missing'.red, false
  #debug 2, File.exist?("#{basedir}/#{modpath2}") ? ', file OK'.green : ', file missing'.red, true
  modexists = File.exist?("#{basedir}/#{modpath}")
  if modxmppath    # modified version *should* exist
    debug 2, "  Mod : #{photo['processed_height']}x#{photo['processed_width']}, #{modpath} ", false
    debug 2, modexists ? '(found)'.green : '(missing)'.red, true
    debug 2, "     => #{moddestpath}".cyan, true  if File.exist?("#{basedir}/#{modpath}")
  end

  exif_rot_orig = ''
  if File.exist?("#{basedir}/#{origpath}") and origpath =~ /jpg$/i \
      and exif_rot_orig = EXIFR::JPEG.new("#{basedir}/#{origpath}").orientation || ''
    exif_rot_orig = convert_exif_rot(exif_rot_orig.to_i)
  end
  exif_rot_mod = ''
  if modexists and modpath =~ /jpg$/i \
      and exif_rot_mod  = EXIFR::JPEG.new("#{basedir}/#{modpath}").orientation || ''
    exif_rot_mod  = convert_exif_rot(exif_rot_mod.to_i)
  end
  #if photo['face_rotation'].to_i != 0 or photo['rotation'] != 0
    debug 2, "  Flip: EXIF #{exif_rot_orig}°/#{exif_rot_mod}°, photo #{photo['rotation']}°, face(s): #{photo['face_rotation']}°".blue, true
  #end

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

  debug 3, '', true

end

eventmetafile.close

unless face_csv_list.empty?
  debug 3, "vers_id,caption,exif_rot_orig,exif_rot_mod,rotation,face_rotation,face_angle,face_dir_angle,visible_rot,face_name,face_key,face_tlx,face_tly,face_trx,face_try,face_blx,face_bly,face_brx,face_bry,face_w,face_h,modface_tlx,modface_tly,modface_w,modface_h", true
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
