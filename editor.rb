#!/usr/bin/ruby
#
#	editor.rb
#
#	There are 4 classes:
#	Screen -- for reading and writing to the screen (Curses)
#	FileBuffer -- for holding and manipulating the text of a file
#	BuffersList -- for managing multiple file buffers
#	BufferHistory -- for undo/redo
#
#
#	Copyright (C) 2011-2012, Jason P. DeVita (jason@wx13.com)
#
#	Copying and distribution of this file, with or without modification,
#	are permitted in any medium without royalty provided the copyright
#	notice and this notice are preserved.  This file is offered as-is,
#	without any warranty.
#

require 'curses'
require 'optparse'
require 'yaml'


#------------------------------------------------------------
# This class will manage the curses screen output.
# It should include all the user interface stuff, such as:
#   - write text to a position on the screen
#   - write status line
#   - ask user a question
# It should not deal with text buffer management or the like.
#------------------------------------------------------------

class Screen

	attr_accessor :rows, :cols

	def initialize
		Curses.raw
		Curses.noecho
	end

	def update_screen_size
		@cols = @screen.maxx
		@rows = @screen.maxy
	end

	# This starts the curses session.
	# When this exits, screen closes.
	def init_screen
		@screen = Curses.init_screen
		Curses.start_color
		Curses.stdscr.keypad(true)
		Curses.init_pair(Curses::COLOR_GREEN, Curses::COLOR_GREEN, Curses::COLOR_BLACK)
		Curses.init_pair(Curses::COLOR_RED, Curses::COLOR_RED, Curses::COLOR_BLACK)
		Curses.init_pair(Curses::COLOR_WHITE, Curses::COLOR_WHITE, Curses::COLOR_BLACK)
		Curses.init_pair(Curses::COLOR_CYAN, Curses::COLOR_CYAN, Curses::COLOR_BLACK)
		Curses.init_pair(Curses::COLOR_BLUE, Curses::COLOR_BLUE, Curses::COLOR_BLACK)
		Curses.init_pair(Curses::COLOR_YELLOW, Curses::COLOR_YELLOW, Curses::COLOR_BLACK)
		Curses.init_pair(Curses::COLOR_MAGENTA, Curses::COLOR_MAGENTA, Curses::COLOR_BLACK)
		begin
			yield
		ensure
			Curses.close_screen
		end
	end

	def suspend(buffer)
		Curses.close_screen
		Process.kill("SIGSTOP",0)
		Curses.refresh
		buffer.dump_to_screen($screen,true)
	end

	# Write a string at a position.
	def write_str(line,column,text)
		if text == nil
			return
		end
		Curses.setpos(line,column)
		Curses.addstr(text)
	end

	# Write a line of text.
	def write_line(row,colfeed,line)

		if line == nil || line == ""
			return
		end

		write_str(row,0," "*@cols)  # clear row

		substrings = line.split($color)  # split at color escape

		# Write from colfeed to first color escape.
		# If colfeed is larger than the first substring,
		# this will naturally write nothing.
		write_str(row,0,substrings[0][colfeed,@cols])
		pos = substrings[0].length
		substrings = substrings[1..-1]
		return if substrings == nil

		# loop over remaining parts of the line
		substrings.each{|substring|
			colorcode = substring[0].chr
			substring = substring[1..-1]
			next if substring == nil
			case colorcode
				when $color_white then set_color(Curses::COLOR_WHITE)
				when $color_red then set_color(Curses::COLOR_RED)
				when $color_green then set_color(Curses::COLOR_GREEN)
				when $color_yellow then set_color(Curses::COLOR_YELLOW)
				when $color_blue then set_color(Curses::COLOR_BLUE)
				when $color_magenta then set_color(Curses::COLOR_MAGENTA)
				when $color_cyan then set_color(Curses::COLOR_CYAN)
				when $color_reverse then @screen.attron(Curses::A_REVERSE)
				when $color_normal then @screen.attroff(Curses::A_REVERSE)
			end
			# pos is position in the line.
			if pos < colfeed
				# We must chop off first part of the substring,
				# because we are writing off the left edge of the screen.
				str_start = colfeed - pos
				col = 0
			else
				# We write the entire string, but starting some number of
				# spaces in from the edge.
				col = pos - colfeed
				str_start = 0
			end
			write_str(row,col,substring[str_start,(@cols-col)])
			pos += substring.length
		}
	end

	def set_color(color)
		@screen.color_set(color)
	end

	# write the info line at top of screen
	def write_top_line(lstr,cstr,rstr)

		update_screen_size
		rstr = cstr + "  " + rstr
		ll = lstr.length
		lr = rstr.length

		# if line is too long, chop off start of left string
		if (ll+lr+3) > @cols
			xxx = @cols - lr - 8
			return if xxx < 0
			lstr = "..." + lstr[(-xxx)..-1]
			ll = lstr.length
		end

		nspaces = @cols - ll - lr
		return if nspaces < 0  # line is too long to write
		all = lstr + (" "*nspaces) + rstr
		@screen.attron Curses::A_REVERSE
		write_str(0,0,all)
		@screen.attroff Curses::A_REVERSE

	end

	# toggle reverse text
	def text_reverse(val)
		if val
			@screen.attron Curses::A_REVERSE
		else
			@screen.attroff Curses::A_REVERSE
		end
	end

	# write a message at the bottom
	def write_message(message)
		update_screen_size
		xpos = (@cols - message.length)/2
		@screen.attroff Curses::A_REVERSE
		write_str(@rows-1,0," "*@cols)
		@screen.attron Curses::A_REVERSE
		write_str(@rows-1,xpos,message)
		@screen.attroff Curses::A_REVERSE
	end


	#
	# Do a reverese incremental search through a history.
	# This is a helper function for asking the user for input.
	#
	def reverse_incremental(hist)

		token = ""  # user's search token
		mline = token  # line which matches token
		ih = hist.length - 1  # position within history list

		# interact with user
		loop do

			# write out current match status
			write_str(@rows-1,0," "*@cols)
			write_str(@rows-1,0,"(reverse-i-search) #{token}: #{mline}")

			# get user input
			c = Curses.getch
			if c.is_a?(String) then c = c.unpack('C')[0] end
			case c
				when Curses::Key::BACKSPACE, $backspace, $backspace2, 8
					# chop off a character, and search for a new match
					token.chop!
					ih = hist.rindex{|x|x.match(/^#{token}/)}
					if ih != nil
						mline = hist[ih]
					end
				when $ctrl_r
					# get next match in reverse list
					if ih == 0
						next
					end
					ih = hist[0..(ih-1)].rindex{|x|x.match(/^#{token}/)}
				when $ctrl_c, $ctrl_g
					# 0 return value = cancelled search
					return 0
				when $ctrl_m, Curses::Key::ENTER
					# non-zero return value is index of the match.
					# We've been searching backwards, so must invert index.
					return hist.length - ih
				when Curses::Key::UP, Curses::Key::DOWN
					# up/down treated same as enter
					return hist.length - ih
				when 10..127
					# regular character
					token += c.chr
					ih = hist[0..ih].rindex{|x|x.match(/^#{token}/)}
			end
			# ajust string for next loop
			if ih != nil
				mline = hist[ih]
			else
				ih = hist.length - 1
			end
		end
	end



	#
	# ask th user a question
	# INPUT:
	#   question  = "string"
	#   history = ["string1","string2"]
	#   last_answer = true/false (start with last hist item as current answe?)
	#   file = true/false (should we do tab-completion on files?)
	#
	def ask(question,hist=[""],last_answer=false,file=false)

		update_screen_size
		@screen.attron Curses::A_REVERSE
		ih = 0  # history index
		token = ""  # potential answer
		if last_answer
			token = hist[-1].dup  # show last item in history
		end
		token0 = token.dup  # remember typed string, even if we move away
		col = token.length  # put cursor at end of string
		write_str(@rows-1,0," "*@cols)  # blank the line
		write_str(@rows-1,0,question+" "+token)
		shift = 0  # shift: in case we go past edge of screen
		idx = 0  # for tabbing through files
		glob = token  # for file globbing

		# interact with user
		loop do
			c = Curses.getch
			if c.is_a?(String) then c = c.unpack('C')[0] end
			case c
				when $ctrl_c then return(nil)
				when Curses::Key::UP
					ih += 1
					if ih >= hist.length
						ih = hist.length-1
					end
					token = hist[-ih].dup
					glob = token
					col = token.length
				when Curses::Key::DOWN
					ih -= 1
					if ih < 0
						ih = 0
					end
					if ih == 0
						token = token0
					else
						token = hist[-ih].dup
					end
					glob = token
					col = token.length
				when $ctrl_r
					ih = reverse_incremental(hist)
					if ih == nil then ih = 0 end
					if ih == 0
						token = token0
					else
						token = hist[-ih].dup
					end
					glob = token
					col = token.length
				when Curses::Key::LEFT
					col -= 1
					if col<0 then col=0 end
					glob = token
				when Curses::Key::RIGHT
					col += 1
					if col>token.length then col = token.length end
					glob = token
				when $ctrl_e
					col = token.length
					glob = token
				when $ctrl_a
					col = 0
					glob = token
				when $ctrl_u
					# cut to start-of-line
					token = token[col..-1]
					glob = token
					col = 0
				when $ctrl_k
					# cut to end-of-line
					token = token[0,col]
					glob = token
				when $ctrl_d
					# delete character at cursor
					if col < token.length
						token[col] = ""
					end
					token0 = token.dup
					glob = token
				when $ctrl_m, Curses::Key::ENTER then break
				when 10..127
					# regular character
					token.insert(col,c.chr)
					token0 = token.dup
					col += 1
					glob = token
				when Curses::Key::BACKSPACE, $backspace, $backspace2, 8
					if col > 0
						token[col-1] = ""
						col -= 1
					end
					token0 = token.dup
					glob = token
				when ?\t, $ctrl_i, 9
					if file
						# find files that match typed string
						# Cycle through matches.
						list = Dir.glob(glob+"*")
						if list.length == 0
							next
						end
						idx = idx.modulo(list.length)
						token = list[idx]
						col = token.length
						idx += 1
					else
						# not a file, so insert literal tab character
						token.insert(col,c.chr)
						token0 = token.dup
						col += 1
						glob = token
					end
			end

			# display the answer so far
			write_str(@rows-1,0," "*$cols)
			if (col+question.length+2) > $cols
				shift = col - $cols + question.length + 2
			else
				shift = 0
			end
			write_str(@rows-1,0,question+" "+token[shift..-1])
			Curses.setpos(@rows-1,(col-shift)+question.length+1)

		end
		@screen.attroff Curses::A_REVERSE
		if token == ""
			token = hist[-1].dup
		end
		if token != hist[-1]
			hist << token
		end
		return(token)
	end




	# ask a yes or no question
	def ask_yesno(question)
		update_screen_size
		@screen.attron Curses::A_REVERSE
		write_str(@rows-1,0," "*@cols)
		write_str(@rows-1,0,question)
		answer = "cancel"
		loop do
			c = Curses.getch
			next if c > 255  # don't accept weird characters
			if c.chr.downcase == "y"
				answer = "yes"
				break
			end
			if c.chr.downcase == "n"
				answer = "no"
				break
			end
			if c == $ctrl_c
				answer = "cancel"
				break
			end
		end
		@screen.attroff Curses::A_REVERSE
		return answer
	end


end



# end of Screen class
#----------------------------------------------------------









# ---------------------------------------------------------
# This is the big main class, which handles a file
# buffer.  Does everything from screen dumps to
# searching etc.
#----------------------------------------------------------

class FileBuffer

	attr_accessor :filename, :text, :editmode, :buffer_history, :extramode

	def initialize(filename)

		# set some parameters
		@tabsize = $tabsize
		@linelength = 0  # 0 means full screen width

		# read in the file
		@filename = filename
		read_file
		# file type for syntax coloring
		set_filetype(@filename)

		# position of cursor in buffer
		@row = 0
		@col = 0
		# position of cursor on screen
		@cursrow = 0
		@curscol = 0
		# shifts of the buffer
		@linefeed = 0
		@colfeed = 0

		# remember if file was CRLF
		@eol = "\n"

		# copy,cut,paste stuff
		@marked = false
		@cutrow = -2  # keep track of last cut row, to check for consecutiveness
		@mark_col = 0
		@mark_row = 0

		# flags
		@autoindent = $autoindent
		@editmode = $editmode
		@extramode = false
		@insertmode = true
		@linewrap = $linewrap
		@colmode = false
		@syntax_color = $syntax_color

		# undo-redo history
		@buffer_history = BufferHistory.new(@text)
		# save up info about screen to detect changes
		@colfeed_old = 0
		@marked_old = false

		# bookmarking stuff
		@bookmarks = {}
		@bookmarks_hist = [""]

		# This does nothing, by default; it is here to allow
		# a user script to modify each text buffer that is opened.
		perbuffer_userscript

	end

	def perbuffer_userscript
	end


	# Enter arbitrary ruby command.
	def enter_command
		answer = $screen.ask("command:",$command_hist)
		eval(answer)
		$screen.write_message("done")
	rescue
		$screen.write_message("Unknown command")
	end


	def run_script
		file = $screen.ask("run script file: ",$scriptfile_hist,false,true)
		if (file==nil) || (file=="")
			$screen.write_message("cancelled")
			return
		end
		if File.directory?(file)
			list = Dir.glob(file+"/*.rb")
			list.each{|f|
				script = File.read(f)
				eval(script)
				$screen.write_message("done")
			}
		elsif File.exist?(file)
			script = File.read(file)
			eval(script)
			$screen.write_message("done")
		else
			$screen.write_message("script file #{file} doesn't exist")
		end
	rescue
		$screen.write_message("Bad script")
	end


	# set the file type from the filename
	def set_filetype(filename)
		$filetypes.each{|k,v|
			if filename.match(k) != nil
				@filetype = v
			end
		}
		# set up syntax coloring
		@syntax_color_lc = $syntax_color_lc[@filetype]
		@syntax_color_bc = $syntax_color_bc[@filetype]
		@syntax_color_regex = $syntax_color_regex[@filetype]
	end


	# remember a position in the text
	def bookmark
		answer = $screen.ask("bookmark:",@bookmarks_hist)
		if answer == nil
			$screen.write_message("Cancelled");
		else
			$screen.write_message("Bookmarked");
			@bookmarks[answer] = [@row,@col]
		end
	end

	def goto_bookmark
		answer = $screen.ask("go to:",@bookmarks_hist)
		if answer == nil
			$screen.write_message("Cancelled")
			return
		end
		rc = @bookmarks[answer]
		if rc == nil
			$screen.write_message("Invalid bookmark")
			return
		end
		@row = rc[0]
		@col = rc[1]
		$screen.write_message("found it")
	end



	# Toggle one of many states.
	# These keys should be a keybinding.
	def toggle
		str = ""
		$togglelist_array.each{|a| str += a[1][2] + ","}
		str.chop!
		$screen.write_message(str)
		c = Curses.getch
		eval($togglelist[c][0])
		$screen.write_message($togglelist[c][1])
	end

	# Go back to edit mode.
	def toggle_editmode
		@editmode = true
		$screen.write_message("Edit mode")
	end


	# Read into buffer array.
	# Called by initialize -- shouldn't need to call
	# this directly.
	def read_file
		if @filename == ""
			@text = [""]
			return
		else
			if File.exists? @filename
				text = IO.read(@filename)
			else
				@text = [""]
				return
			end
		end
		# get rid of crlf
		temp = text.gsub!(/\r\n/,"\n")
		if temp == nil
			@eol = "\n"
		else
			@eol = "\r\n"
		end
		text.gsub!(/\r/,"\n")
		@text = text.split("\n",-1)
	end

	# Save buffer to a file.
	def save
		# Ask the user for a file.
		# Defaults to current file.
		ans = $screen.ask("save to: ",[@filename],true,true)
		if ans == nil
			$screen.write_message("Cancelled")
			return
		end
		if ans == "" then ans = @filename end
		if ans == ""
			$screen.write_message("Cancelled")
			return
		end
		# If name is different from current file name,
		# ask for verification.
		if ans != @filename
			yn = $screen.ask_yesno("save to different file: "+ans+" ? [y/n]")
			if yn == "yes"
				@filename = ans
				set_filetype(@filename)
			else
				$screen.write_message("aborted")
				return
			end
		end
		# Dump the text to the file.
		File.open(@filename,"w"){|file|
			text = @text.join(@eol)
			file.write(text)
		}
		# Let the undo/redo history know that we have saved,
		# for revert-to-saved purposes.
		@buffer_history.save
		# Save the command/search histories.
		if $hist_file != nil
			$buffers.save_hists
		end
		$screen.write_message("saved to: "+@filename)
	end


	# make sure file position is valid
	def sanitize
		if @text.length == 0
			@text = [""]
			@row = 0
			@col = 0
			return
		end
		if @row >= @text.length
			@row = @text.length - 1
		end
		if @col > @text[@row].length
			@col = @text[@row].length
		end
	end


	def modified?
		@buffer_history.modified?
	end


	#
	# Modifying text
	#

	# These are the functions which do the mods.
	# Everything else calls these.

	# delete a character
	def delchar(row,col)
		if col == @text[row].length
			mergerows(row,row+1)
		else
			@text[row] = @text[row].dup
			@text[row][col] = ""
		end
	end
	# insert a character
	def insertchar(row,col,c)
		if @text[row] == nil
			@text[row] = c
			return
		end
		@text[row] = @text[row].dup
		if @insertmode || col == @text[row].length
			@text[row].insert(col,c)
		else
			@text[row][col] = c
		end
	end
	# delete a row
	def delrow(row)
		@text.delete_at(row)
	end
	# delete a range of rows (inclusive)
	def delrows(row1,row2)
		@text[row1..row2] = []
	end
	# merge two consecutive rows
	def mergerows(row1,row2)
		if row2 >= @text.length
			return
		end
		col = @text[row1].length
		@text[row1] = @text[row1].dup
		@text[row1] += @text[row2]
		@text.delete_at(row2)
	end
	# split a row into two
	def splitrow(row,col)
		text = @text[row].dup
		@text[row] = text[(col)..-1]
		insertrow(row,text[0..(col-1)])
	end
	# new row
	def insertrow(row,text)
		@text.insert(row,text)
	end
	# multiple new rows
	def insertrows(row,text_array)
		@text.insert(row,text_array).flatten!
	end
	# completely change a row's text
	def setrow(row,text)
		old = @text[row]
		@text[row] = text
	end
	# add to the end of a line
	def append(row,text)
		@text[row] = @text[row].dup
		@text[row] += text
	end
	# insert a string
	def insert(row,col,text)
		@text[row] = @text[row].dup
		@text[row].insert(col,text)
	end
	# backspace a column of text
	def column_backspace(row1,row2,col)
		if col == 0 then return end
		sc = bc2sc(@row,col)
		for r in row1..row2
			c = sc2bc(r,sc)
			if @text[r].length == 0 then next end
			if c<=0 then next end
			@text[r] = @text[r].dup
			@text[r][c-1] = ""
		end
		cursor_left
	end
	# delete a column of text
	def column_delete(row1,row2,col)
		sc = bc2sc(@row,col)
		for r in row1..row2
			c = sc2bc(r,sc)
			if c<0 then next end
			if c==@text[r].length then next end
			@text[r] = @text[r].dup
			@text[r][c] = ""
		end
	end


	#
	# Undo / redo
	#
	def undo
		if @buffer_history.prev != nil
			@buffer_history.tree = @buffer_history.prev
			@text = @buffer_history.copy
			@col = 0
			@row = row_changed(@text,@buffer_history.next.text,@row)
		end
	end
	def redo
		if @buffer_history.next != nil
			@buffer_history.tree = @buffer_history.next
			@text = @buffer_history.copy
			@col = 0
			@row = row_changed(@text,@buffer_history.prev.text,@row)
		end
	end
	def revert_to_saved
		@text = @buffer_history.revert_to_saved
	end
	def unrevert_to_saved
		@text = @buffer_history.unrevert_to_saved
	end
	def row_changed(text1,text2,r)
		n = [text1.length,text2.length].min
		text1.each_index{|i|
			if i >= n then break end
			if text1[i] != text2[i]
				return(i)
			end
		}
		return(r)
	end



	# these functions all call the mod function
	# but don't modify the buffer directly

	def ordered_mark_rows
		if @row < @mark_row
			row = @mark_row
			mark_row = @row
		else
			row = @row
			mark_row = @mark_row
		end
		return mark_row,row
	end
	# delete a character
	def delete
		if @marked
			mark_row,row = ordered_mark_rows
			if @colmode
				column_delete(mark_row,row,@col)
			else
				column_delete(mark_row,row,0)
			end
		else
			delchar(@row,@col)
		end
	end
	# backspace over a character
	def backspace
		if @marked
			mark_row,row = ordered_mark_rows
			if @colmode
				column_backspace(mark_row,row,@col)
			else
				column_backspace(mark_row,row,1)
			end
		else
			if (@col+@row)==0
				return
			end
			if @col == 0
				cursor_left
				mergerows(@row,@row+1)
				return
			end
			cursor_left
			delchar(@row,@col)
		end
	end
	# indent a line or block of text
	def indent
		if @marked
			mark_row,row = ordered_mark_rows
			block_indent(mark_row,row)
		else
			addchar(?\t)
		end
	end
	# insert a char and move to the right
	def addchar(c)
		if @marked == false
			insertchar(@row,@col,c.chr)
		else
			mark_row,row = ordered_mark_rows
			for r in mark_row..row
				if (@text[r].length==0)&&((c==?\s)||(c==?\t)||(c==$ctrl_i)||(c==$space))
					next
				end
				if @colmode
					sc = bc2sc(@row,@col)
					cc = sc2bc(r,sc)
					if(cc>@text[r].length) then next end
					insertchar(r,cc,c.chr)
				else
					insertchar(r,0,c.chr)
				end
			end
		end
		cursor_right
		if @linewrap
			justify(true)
		end
	end
	# add a line-break
	def newline
		if @marked then return end
		if @col == 0
			insertrow(@row,"")
			cursor_down(1)
		else
			splitrow(@row,@col)
			ws = ""
			if @autoindent
				ws = ""
				if @row > 1
					s0 = @text[@row-2].dup
					s1 = @text[@row-1].dup
					s2 = @text[@row].dup
					ml = [s0.length,s1.length,s2.length].min
					s0 = s0[0,ml]
					s1 = s1[0,ml]
					s2 = s2[0,ml]
					until (s1==s2)&&(s0==s1)
						s0.chop!
						s1.chop!
						s2.chop!
					end
					ws = s2
				end
				a = @text[@row].match(/^\s*/)
				if a != nil
					ws2 = a[0]
				end
				ws = [ws,ws2].max
				# if current line is just whitespace, remove it
				if @text[@row].match(/^\s*$/)
					@text[@row] = ""
				end
				insertchar(@row+1,0,ws)
			end
			@col = ws.length
			@row += 1
		end
	end

	# justify a block of text
	def justify(linewrap=false)

		if @linelength == 0 then @linelength = $screen.cols end

		if linewrap
			cols = @linelength
			if @text[@row].length < cols then return end
		else
			# ask for screen width
			# nil means cancel, empty means screen width
			ans = $screen.ask("Justify width: ",[@linelength.to_s],true)
			if ans == nil
				$screen.write_message("Cancelled")
				return
			end
			if ans == ""
				cols = @linelength
			elsif ans == "0"
				cols = $screen.cols
			elsif ans.to_i < 0
				cols = $screen.cols + ans.to_i
			else
				cols = ans.to_i
			end
			@linelength = cols
		end

		# set start & end rows
		if @marked
			mark_row, row = ordered_mark_rows
		else
			mark_row = @row
			row = @row
		end
		nl = row - mark_row + 1

		# make one long line out of multiple lines
		text = @text[mark_row..row].join(" ")
		for r in mark_row..row
			delrow(mark_row)
		end

		# loop through words and check length
		c = 0
		r = mark_row
		loop do
			c2 = text.index(/([^\s]\s)|($)/,c)  # end of next word
			if c2 == nil then break end  # end, if no more words
			# if we are past the edge, then put it in the next row
			# Otherwise, keep going.
			if c2 >= (cols-1)
				if c == 0 then c = c2+1 end  # careful about long words
				insertrow(r,text[0,c])
				text = text[c..-1]
				if text == nil then text = "" end
				text.lstrip!
				r += 1
				c = 0
			else
				c = c2+1
			end
			if text == nil || text == ""
				text = ""
				break
			end
		end
		insertrow(r,text)
		$screen.write_message("Justified to "+cols.to_s+" columns")
		if linewrap
			if @col >= @text[@row].length+1
				@col = @col - @text[@row].length - 1
				@row += 1
			end
		else
			@row = r
			@col = 0
		end
		@marked = false
	end


	#
	# Navigation stuff
	#

	def cursor_right
		@col += 1
		if @col > @text[@row].length
			if @row < (@text.length-1)
				@col = 0
				@row += 1
			else
				@col -= 1
			end
		end
	end
	def cursor_left
		@col -= 1
		if @col < 0
			if @row > 0
				@col = @text[@row-1].length
				@row -= 1
			else
				@col = 0
			end
		end
	end
	def cursor_eol
		@col = @text[@row].length
	end
	def cursor_sol
		ws = @text[@row].match(/^\s+/)
		if ws == nil
			ns = 0
		else
			ns = ws[0].length
		end
		if @col > ns
			@col = ns
		elsif @col == 0
			@col = ns
		else
			@col = 0
		end
	end
	def cursor_down(n)
		sc = bc2sc(@row,@col)
		@row += n
		if @row >= @text.length
			@row = @text.length-1
		end
		@col = sc2bc(@row,sc)
	end
	def cursor_up(n)
		sc = bc2sc(@row,@col)
		@row -= n
		if @row < 0
			@row = 0
		end
		@col = sc2bc(@row,sc)
	end
	def goto_line
		num = $screen.ask("go to line:",$lineno_hist)
		if num == nil
			$screen.write_message("Cancelled")
			return
		end
		@row = num.to_i
		@col = 0
		if @row < 0
			@row = @text.length + @row
		end
		if @row >= @text.length
			@row = @text.length - 1
		end
		$screen.write_message("went to line "+@row.to_s)
	end
	def screen_left
		@colfeed += 1
	end
	def screen_right
		@colfeed = [0,@colfeed-1].max
	end
	def screen_up
		@linefeed = [0,@linefeed-1].max
	end
	def screen_down
		@linefeed += 1
	end


	#
	# search
	#
	def search(p)
		if p == 0
			# get search string from user
			token = $screen.ask("Search:",$search_hist)
		elsif
			token = $search_hist[-1]
		end
		if token == nil || token == ""
			$screen.write_message("Cancelled")
			return
		end
		# is it a regexp
		if token.match(/^\/.*\/$/) != nil
			token = eval(token)
		end
		nlines = @text.length
		row = @row
		if p >= 0
			# find first match from this line down
			# start with current line
			idx = @text[row].index(token,@col+1)
			while(idx==nil)
				row = (row+1).modulo(nlines)  # next line
				idx = @text[row].index(token)
				if (row == @row) && (idx==nil)  # stop if we wrap back around
					$screen.write_message("No matches")
					return
				end
			end
		else
			if @col > 0
				idx = @text[row].rindex(token,@col-1)
			else
				idx = nil
			end
			while(idx==nil)
				row = (row-1)
				if row < 0 then row = nlines-1 end
				idx = @text[row].rindex(token)
				if (row == @row) && (idx==nil)
					$screen.write_message("No matches")
					return
				end
			end
		end
		$screen.write_message("Found match")
		@row = row
		@col = idx
	end
	def search_and_replace
		# get starting point, so we can return
		row0 = @row
		col0 = @col
		# get search string from user
		token = $screen.ask("Search:",$search_hist)
		if token == nil
			$screen.write_message("Cancelled")
			return
		end
		# is it a regexp
		if token.match(/^\/.*\/$/) != nil
			token = eval(token)
		end
		# get replace string from user
		replacement = $screen.ask("Replace:",$replace_hist)
		if replacement == nil
			$screen.write_message("Cancelled")
			return
		end
		row = @row
		col = @col
		sr = @row
		sc = @col
		loop do
			nlines = @text.length
			idx = @text[row].index(token,col)
			while(idx!=nil)
				str = @text[row][idx..-1].scan(token)[0]
				@row = row
				@col = idx
				dump_to_screen($screen,true)
				highlight(row,idx,idx+str.length-1)
				yn = $screen.ask_yesno("Replace this occurance?")
				l = str.length
				if yn == "yes"
					temp = @text[row].dup
					@text[row] = temp[0,idx]+replacement+temp[(idx+l)..-1]
					col = idx+replacement.length
				elsif yn == "cancel"
					dump_to_screen($screen,true)
					$screen.write_message("Cancelled")
					@row = row0
					@col = col0
					return
				else
					col = idx+replacement.length
				end
				if col > @text[row].length
					break
				end
				idx = @text[row].index(token,col)
			end
			row = (row+1).modulo(nlines)
			col = 0
			if row == sr then break end
		end
		@row = row0
		@col = col0
		dump_to_screen($screen,true)
		$screen.write_message("No more matches")
	end


	#
	# copy/paste
	#
	def mark
		if @marked
			@marked = false
			$screen.write_message("Unmarked")
			return
		end
		@marked = true
		$screen.write_message("Marked")
		@mark_col = @col
		@mark_row = @row
	end


	def copy(cut=0)
		# if this is continuation of a line by line copy
		# then we add to the copy buffer
		if @marked
			$copy_buffer = ""
			@marked = false
		else
			if @row!=(@cutrow+1-cut)
				$copy_buffer = ""
			end
			@cutrow = @row
			@mark_row = @row
			@mark_col = 0
			@col = @text[@row].length
		end

		# rectify row, mark_row order
		if @row == @mark_row
			if @col < @mark_col
				temp = @col
				@col = @mark_col
				@mark_col = temp
			end
		elsif @row < @mark_row
			temp = @row
			@row = @mark_row
			@mark_row = temp
		end

		temp = @text[@mark_row..@row].join("\n") + "\n"
		sc = @mark_col
		ec = temp.length - 1 - (@text[@row].length-@col)
		$copy_buffer += temp[sc..ec]

		if cut==1
			if @col < @text[@row].length
				setrow(@mark_row,@text[@mark_row][0,@mark_col]+@text[@row][(@col+1)..-1])
				delrows(@mark_row+1,@row)
			elsif (@row+1) >= @text.length
				setrow(@mark_row,@text[@mark_row][0,@mark_col])
				delrows(@mark_row+1,@row)
			else
				setrow(@mark_row,@text[@mark_row][0,@mark_col]+@text[@row+1])
				delrows(@mark_row+1,@row+1)
			end
		end

		# position cursor
		if cut == 1
			@row = @mark_row
			@col = @mark_col
		else
			@row = @mark_row + 1
			@col = 0
		end

	end


	def cut
		copy(1)
	end


	def paste
		@cutrow = -2

		# merge current line with copy buffer
		copy_buffer = @text[@row][0,@col] + $copy_buffer + @text[@row][@col..-1]

		# turn buffer into an array
		nlines = $copy_buffer.count("\n")
		copy_array = copy_buffer.split("\n",-1)
		if copy_array[0] == nil
			copy_array[0] = ""
		end

		# insert first line (replace current line)
		setrow(@row,copy_array[0])

		# insert the rest (insert after current line)
		@row += 1
		insertrows(@row,copy_array[1..-1])
		@row += nlines - 1

		# reset cursor for multi-line paste
		if nlines > 0
			@col = 0
		end
	end





	#
	# display text
	#

	# write everything, including status lines
	def dump_to_screen(screen,refresh=false)
		# get cursor position
		ypos = @row - @linefeed
		if ypos < 0
			@linefeed += ypos
			ypos = 0
		elsif ypos >= screen.rows - 3
			@linefeed += ypos + 3 - screen.rows
			ypos = screen.rows - 3
		end
		@cursrow = ypos+1
		@curscol = bc2sc(@row,@col) - @colfeed
		if @curscol > (screen.cols-1)
			@colfeed += @curscol - screen.cols + 1
			@curscol = screen.cols - 1
		end
		if @curscol < 0
			@colfeed += @curscol
			@curscol = 0
		end
		# report on cursor position
		r = (@linefeed+@cursrow-1)
		c = (@colfeed+@curscol)
		r0 = @text.length - 1
		position = r.to_s + "/" + r0.to_s + "," + c.to_s
		if @buffer_history.modified?
			status = "Modified"
		else
			status = ""
		end
		if !@editmode
			status = status + "  VIEW"
		end
		# report on number of open buffers
		if $buffers.nbuf <= 1
			lstr = @filename
		else
			nb = $buffers.nbuf
			ib = $buffers.ibuf
			lstr = sprintf("%s (%d/%d)",@filename,ib+1,nb)
		end
		screen.write_top_line(lstr,status,position)
		# write the text to the screen
		dump_text(screen,refresh)
		if @extramode
			$screen.write_message("EXTRAMODE")
		end
		# set cursor position
		Curses.setpos(@cursrow,@curscol)
	end
	#
	# just dump the buffer text to the screen
	#
	def dump_text(screen,refresh=false)
		# get only the rows of interest
		text = @text[@linefeed,screen.rows-2]
		# store up lines
		screen_buffer = []
		ir = 0
		text.each{ |line|
			ir += 1
			sline = tabs2spaces(line)
			if @syntax_color
				aline = syntax_color(sline)
			else
				aline = sline
			end
			screen_buffer.push(aline)
		}
		# vi-style blank lines
		ir+=1
		while ir < (screen.rows-1)
			screen_buffer.push("~"+" "*(screen.cols-1))
			ir += 1
		end

		#write out the text
		ir = 0
		if (@colfeed==@colfeed_old) && (@marked==false) \
		&& (@marked_old==false) && (refresh==false)
			screen_buffer.each { |line|
				ir += 1
				if ($screen_buffer.length >= ir) && (line == $screen_buffer[ir-1])
					next
				end
				screen.write_line(ir,@colfeed,line)
			}
		else
			screen_buffer.each { |line|
				ir += 1
				screen.write_line(ir,@colfeed,line)
			}
		end
		$screen_buffer = screen_buffer.dup
		@colfeed_old = @colfeed
		@marked_old = @marked
		# now go back and do marked text highlighting
		if @marked
			if @row == @mark_row
				if @col < @mark_col
					col = @mark_col
					mark_col = @col
				else
					col = @col
					mark_col = @mark_col
				end
				if @colmode == false
					highlight(@row,mark_col,col)
				end
			else
				if @row < @mark_row
					row = @mark_row
					mark_row = @row
					col = @mark_col
					mark_col = @col
				else
					row = @row
					mark_row = @mark_row
					col = @col
					mark_col = @mark_col
				end
				if @colmode
					sc = bc2sc(@row,@col)
					for r in mark_row..row
						c = sc2bc(r,sc)
						highlight(r,c,c)
					end
				else
					sl = @text[mark_row].length
					highlight(mark_row,mark_col,sl)
					for r in (mark_row+1)..(row-1)
						sl = @text[r].length
						highlight(r,0,sl)
					end
					highlight(row,0,col)
				end
			end
		end
	end

	# highlight a particular row, from scol to ecol
	# scol & ecol are columns in the text buffer
	def highlight(row,scol,ecol)
		# only do rows that are on the screen
		if row < @linefeed then return end
		if row > (@linefeed + $screen.rows - 2) then return end

		if @text[row].length < 1 then return end

		# convert pos in text to pos on screen
		sc = bc2sc(row,scol)
		ec = bc2sc(row,ecol)

		# replace tabs with spaces
		sline = tabs2spaces(@text[row])
		# get just string of interest
		if sc < @colfeed then sc = @colfeed end
		if ec < @colfeed then return end
		str = sline[sc..ec]
		if ec == sline.length then str += " " end
		ssc = sc - @colfeed
		sec = ec - @colfeed

		if (str.length+ssc) >= $screen.cols
			str = str[0,($screen.cols-ssc)]
		end

		$screen.text_reverse(true)
		$screen.write_str((row-@linefeed+1),ssc,str)
		$screen.text_reverse(false)
	end



	def syntax_find_match(cline,cqc,bline)
		bline += cline[0].chr
		cline = cline[1..-1]
		k = cline.index(cqc)
		if k==nil
			bline += cline
			cline = ""
			return(bline)
		end
		while (k!=nil) && (k>0) && (cline[k-1].chr=="\\") do
			bline += cline[0,k+cqc.length]
			cline = cline[k+cqc.length..-1]
			break if cline == nil
			k = cline.index(cqc)
		end
		if k==nil
			bline += cline
			return(bline)
		end
		if cline == nil
			return(bline)
		end
		bline += cline[0..k+cqc.length-1]
		cline = cline[k+cqc.length..-1]
		return bline,cline
	end



	#
	# Do string and comment coloring.
	# INPUT:
	#   aline -- line of text to color
	#   lccs  -- line comment characters
	#            (list of characters that start comments to end-of-line)
	#   bccs  -- block comment characters
	#            (pairs of comment characters, such as /* */)
	# OUTPUT:
	#   line with color characters inserted
	#
	def syntax_color_string_comment(aline,lccs,bccs)

		dqc = '"'
		sqc = '\''
		dquote = false
		squote = false
		comment = false
		bline = ""
		escape = false

		cline = aline.dup
		while (cline!=nil)&&(cline.length>0) do

			# find first occurance of special character
			all = Regexp.union([lccs,bccs.keys,dqc,sqc,"\\"].flatten)
			k = cline.index(all)
			if k==nil
				bline += cline
				break
			end
			bline += cline[0..(k-1)] if k > 0
			cline = cline[k..-1]

			# if it is an escape, then move down 2 chars
			if cline[0].chr == "\\"
				r = cline[0,2]
				if r != nil
					bline += r
				end
				cline = cline[2..-1]
				next
			end

			# if eol comment, then we are done
			flag = false
			lccs.each{|str|
				if cline.index(str)==0
					bline += $color+$color_comment
					bline += cline
					bline += $color+$color_default
					flag = true
					break
				end
			}
			break if flag

			# block comments
			flag = false
			bccs.each{|sc,ec|
				if cline.index(sc)==0
					flag = true
					bline += $color+$color_comment
					bline,cline = syntax_find_match(cline,ec,bline)
					bline += $color+$color_default
				end
			}
			next if flag

			# if quote, then look for match
			if (cline[0].chr == sqc) || (cline[0].chr == dqc)
				cqc = cline[0].chr
				bline += $color+$color_string
				bline,cline = syntax_find_match(cline,cqc,bline)
				bline += $color+$color_default
				next
			end

			bline += cline[0].chr
			cline = cline[1..-1]
		end

		aline = bline + $color+$color_default
		return aline
	end



	def syntax_color(sline)
		aline = sline.dup
		# trailing whitespace
		aline.gsub!(/\s+$/,$color+$color_whitespace+$color+$color_reverse+"\\0"+$color+$color_normal+$color+$color_default)
		# comments & quotes
		aline = syntax_color_string_comment(aline,@syntax_color_lc,@syntax_color_bc)
		# general regex coloring
		@syntax_color_regex.each{|k,v|
			aline.gsub!(k,$color+v+"\\0"+$color+$color_default)
		}
		return(aline)
	end


	# functions for converting from column position in buffer
	# to column position on screen
	def bc2sc(row,col)
		if @text[row] == nil
			return(0)
		end
		text = @text[row][0,col]
		if text == nil
			return(0)
		end
		text2 = tabs2spaces(text)
		if text2 == nil
			n = 0
		else
			n = text2.length
		end
		return(n)
	end
	def sc2bc(row,col)
		bc = 0
		sc = 0
		if @text[row] == nil then return end
		@text[row].each_char{|c|
			if c == "\t"
				sc += @tabsize
				sc -= sc.modulo(@tabsize)
			else
				sc += 1
			end
			if sc > col then break end
			bc += 1
		}
		return(bc)
	end
	def tabs2spaces(line)
		if line == nil then return(nil) end
		if line.length == 0 then return(line) end
		a = line.split("\t",-1)
		ans = a[0]
		a = a[1..-1]
		if a == nil then return(ans) end
		a.each{|str|
			n = ans.length
			m = @tabsize - (n+@tabsize).modulo(@tabsize)
			ans += " "*m + str
		}
		return(ans)
	end

end






#
# Linked list of buffer text states for undo/redo
#
# Whole thing is a wrapper around a linked list of Node objects,
# which are defined inside this BufferHistory class.
#
class BufferHistory

	attr_accessor :tree

	def initialize(text)
		@tree = Node.new(text)
		@tree.next = nil
		@tree.prev = nil
		@saved = @tree
		@old = @tree
	end

	class Node
		attr_accessor :next, :prev, :text
		def initialize(text)
			@text = []
			for k in 0..(text.length-1)
				@text[k] = text[k]
			end
		end
		def delete
			@text = nil
			if @next != nil then @next.prev = @prev end
			if @prev != nil then @prev.next = @next end
		end
	end

	# add a new snapshot
	def add(text)

		# create a new node and set navigation pointers
		@old = @tree
		@tree = Node.new(text)
		@tree.next = @old.next
		if @old.next != nil
			@old.next.prev = @tree
		end
		@tree.prev = @old
		@old.next = @tree

		# Prune the tree, so it doesn't get too big.
		# Start by going back.
		n=0
		x = @tree
		while x != nil
			n += 1
			x0 = x
			x = x.prev
		end
		x = x0
		while n > 500
			n -= 1
			x = x.next
			x.prev.delete
		end
		# now forward
		n=0
		x = @tree
		while x != nil
			n += 1
			x0 = x
			x = x.next
		end
		x = x0
		while n > 500
			n -= 1
			x = x.prev
			x.next.delete
		end
	end

	# get the current text state
	def text
		@tree.text
	end

	# Shallow copy
	def copy
		atext = []
		for k in 0..(@tree.text.length-1)
			atext[k] = @tree.text[k]
		end
		return(atext)
	end
	def prev
		if @tree.prev == nil
			return(@tree)
		else
			return(@tree.prev)
		end
	end
	def next
		if @tree.next == nil
			return(@tree)
		else
			return(@tree.next)
		end
	end
	def delete
		if (@tree.next==nil)&&(@tree.prev==nil)
			return(@tree)
		else
			@tree.delete
			if @tree.next == nil
				return(@tree.prev)
			else
				return(@tree.next)
			end
		end
	end
	def save
		@saved = @tree
	end
	def modified?
		@saved.text != @tree.text
	end
	def revert_to_saved
		@old = @tree
		@tree = @saved
		return(copy)
	end
	def unrevert_to_saved
		@tree = @old
		return(copy)
	end
end





#
# this is a list of buffers
#
class BuffersList

	attr_accessor :copy_buffer, :nbuf, :ibuf

	# Read in all input files into buffers.
	# One buffer for each file.
	def initialize(files)
		@buffers = []
		@nbuf = 0
		@ibuf = 0
		#@copy_buffer = ""
		for filename in files
			@buffers[@nbuf] = FileBuffer.new(filename)
			@nbuf += 1
		end
		if @nbuf == 0
			@buffers[@nbuf] = FileBuffer.new("")
			@nbuf += 1
		end
		if ($hist_file != nil) && (File.exist?($hist_file))
			read_hists
		end
	end

	# return next, previous, or current buffer
	def next
		@ibuf = (@ibuf+1).modulo(@nbuf)
		@buffers[@ibuf]
	end
	def prev
		@ibuf = (@ibuf-1).modulo(@nbuf)
		@buffers[@ibuf]
	end
	def current
		@buffers[@ibuf]
	end

	# close a buffer
	def close
		if @buffers[@ibuf].modified?
			ys = $screen.ask_yesno("Save changes?")
			if ys == "yes"
				@buffers[@ibuf].save
			elsif ys == "cancel"
				$screen.write_message("Cancelled")
				return(@buffers[@ibuf])
			end
		end
		@buffers.delete_at(@ibuf)
		@nbuf -= 1
		@ibuf = 0
		$screen.write_message("")
		if @nbuf == 0 || @buffers[0] == nil
			if $hist_file != nil
				save_hists
			end
			exit
		end
		@buffers[0]
	end

	def save_hists
		if ($hist_file != nil) && (File.exist?($hist_file))
			read_hists
		end
		hists = {"search_hist" => $search_hist.reverse[0,1000].reverse,\
	             "replace_hist" => $replace_hist.reverse[0,1000].reverse,\
	             "command_hist" => $command_hist.reverse[0,1000].reverse,\
	             "script_hist" => $scriptfile_hist.reverse[0,1000].reverse\
	            }
		File.open($hist_file,"w"){|file|
			YAML.dump(hists,file)
		}
	end

	def read_hists
		if ($hist_file == nil) || (!File.exist?($hist_file))
			return
		end
		hists = YAML.load_file($hist_file)
		if !hists
			return
		end
		$search_hist.concat(hists["search_hist"]).uniq!
		$replace_hist.concat(hists["replace_hist"]).uniq!
		$command_hist.concat(hists["command_hist"]).uniq!
		$script_hist.concat(hists["script_hist"]).uniq!
	end

	def open
		ans = $screen.ask("open file: ",[""],false,true)
		if (ans==nil) || (ans == "")
			$screen.write_message("cancelled")
			return(@buffers[@ibuf])
		end
		@buffers[@nbuf] = FileBuffer.new(ans)
		@nbuf += 1
		@ibuf = @nbuf-1
		$screen.write_message("Opened file: "+ans)
		return(@buffers[@ibuf])
	end

end




#----------------------------------------------------------



# ---------------- global function ----------------------

# allow user scripts
def run_script(file=nil)
	if file == nil
		file = $screen.ask("run script file: ",[""],false,true)
		if (file==nil) || (file=="")
			$screen.write_message("cancelled")
			return
		end
	end
	if File.directory?(file)
		list = Dir.glob(file+"/*.rb")
		list.each{|f|
			script = File.read(f)
			eval(script)
			if $screen != nil
				$screen.write_message("done")
			end
		}
	elsif File.exist?(file)
		script = File.read(file)
		eval(script)
		if $screen != nil
			$screen.write_message("done")
		end
	else
		puts "Script file #{file} doesn't exist."
		puts "Press any key to continue anyway."
		STDIN.getc
	end
rescue
	if $screen != nil
		$screen.write_message("Bad script")
	else
		puts "Bad script file: #{file}"
		puts "Press any key to continue anyway."
		STDIN.getc
	end
end
# --------------------------------------------------------






# -----------------------------------------------------------------
# This section defines some global constants.  Don't change these
# unless you know what you're doing.
# -----------------------------------------------------------------

# control & meta chracters -- the \C-a type thing seems to only
# sometimes work
$ctrl_space = 0
$ctrl_a = 1
$ctrl_b = 2
$ctrl_c = 3
$ctrl_d = 4
$ctrl_e = 5
$ctrl_f = 6
$ctrl_g = 7
$ctrl_h = 8
$ctrl_i = 9
$ctrl_j = 10
$ctrl_k = 11
$ctrl_l = 12
$ctrl_m = 10
$enter = 10
$ctrl_n = 14
$ctrl_o = 15
$ctrl_p = 16
$ctrl_q = 17
$ctrl_r = 18
$ctrl_s = 19
$ctrl_t = 20
$ctrl_u = 21
$ctrl_v = 22
$ctrl_w = 23
$ctrl_x = 24
$ctrl_y = 25
$ctrl_z = 26
$ctrl_3 = 27
$ctrl_4 = 28
$ctrl_5 = 29
$ctrl_6 = 30
$ctrl_7 = 31
$ctrl_8 = 127
$backspace = 127
$backspace2 = 263
$space = 32

# color escape
$color = "\300"
$color_white = "\301"
$color_red = "\302"
$color_green = "\303"
$color_blue = "\304"
$color_cyan = "\305"
$color_magenta = "\306"
$color_yellow = "\307"
$color_black = "\308"
# highlighting
$color_normal = "\310"
$color_reverse = "\311"

# default text colors
$color_default = $color_white
$color_comment = $color_cyan
$color_string = $color_yellow
$color_whitespace = $color_red

# define file types for syntax coloring
$filetypes = {
	/\.sh$/ => "shell",
	/\.csh$/ => "shell",
	/\.rb$/ => "shell",
	/\.py$/ => "shell",
	/\.[cC]$/ => "c",
	/\.cpp$/ => "c",
	"COMMIT_EDITMSG" => "shell",
	/\.m$/ => "m",
	/\.[fF]$/ => "f"
}

# --- default syntax coloring rules ---
# line comments
$syntax_color_lc = {
	"shell" => ["#"],
	"ruby" => ["#"],
	"c" => ["//"],
	"f" => ["!",/^c/],
	"idl" => [";"]
}
$syntax_color_lc.default = []
# block comments
$syntax_color_bc = {
	"c" => {"/*"=>"*/"},
}
$syntax_color_bc.default = {}
# general regex
$syntax_color_regex = {}
$syntax_color_regex.default = {}


# default config
$tabsize = 4
$autoindent = true
$linewrap = false
$colmode = false
$syntax_color = true
$editmode = true




# -----------------------------------------------------------------
# This section defines the keymapping.
# There are 5 sections:
#     1. commandlist -- universal keymapping
#     2. editmode_commandlist -- keymappings when in edit mode
#     3. viewmode_commandlist -- keymappings in view mode
#     4. extra_commandlist -- ones that don't fit
#     5. togglelist -- for toggling states on/off
#     	 These get run when buffer.toggle is run.
#        It is an array, because I want to preserve order.
# -----------------------------------------------------------------


$commandlist = {
	$ctrl_q => "buffer = $buffers.close",
	Curses::Key::UP => "buffer.cursor_up(1)",
	Curses::Key::DOWN => "buffer.cursor_down(1)",
	Curses::Key::RIGHT => "buffer.cursor_right",
	Curses::Key::LEFT => "buffer.cursor_left",
	Curses::Key::NPAGE => "buffer.cursor_down($rows-3)",
	Curses::Key::PPAGE => "buffer.cursor_up($rows-3)",
	$ctrl_v => "buffer.cursor_down($rows-3)",
	$ctrl_y => "buffer.cursor_up($rows-3)",
	$ctrl_e => "buffer.cursor_eol",
	$ctrl_a => "buffer.cursor_sol",
	$ctrl_n => "buffer = $buffers.next",
	$ctrl_b => "buffer = $buffers.prev",
	$ctrl_x => "buffer.mark",
	$ctrl_p => "buffer.copy",
	$ctrl_w => "buffer.search(0)",
	$ctrl_g => "buffer.goto_line",
	$ctrl_o => "buffer.save",
	$ctrl_f => "buffer = $buffers.open",
	$ctrl_z => "$screen.suspend(buffer)",
	$ctrl_t => "buffer.toggle",
	$ctrl_6 => "buffer.extramode = true",
	$ctrl_s => "buffer.run_script"
}
$commandlist.default = ""
$extramode_commandlist = {
	?b => "buffer.bookmark",
	?g => "buffer.goto_bookmark"
}
$extramode_commandlist.default = ""
$editmode_commandlist = {
	Curses::Key::BACKSPACE => "buffer.backspace",
	$backspace => "buffer.backspace",
	$backspace2 => "buffer.backspace",
	8 => "buffer.backspace",
	$enter => "buffer.newline",
	$ctrl_k => "buffer.cut",
	$ctrl_u => "buffer.paste",
	$ctrl_m => "buffer.newline",
	$ctrl_j => "buffer.newline",
	$ctrl_d => "buffer.delete",
	$ctrl_r => "buffer.search_and_replace",
	$ctrl_l => "buffer.justify",
	$ctrl_i => "buffer.addchar(c)",
	9 => "buffer.addchar(c)",
}
$editmode_commandlist.default = ""
$viewmode_commandlist = {
	?q => "buffer = $buffers.close",
	?k => "buffer.cursor_up(1)",
	?j => "buffer.cursor_down(1)",
	?l => "buffer.cursor_right",
	?h => "buffer.cursor_left",
	$space => "buffer.cursor_down($rows-3)",
	?b => "buffer.cursor_up($rows-3)",
	?. => "buffer = $buffers.next",
	?, => "buffer = $buffers.prev",
	?/ => "buffer.search(0)",
	?n => "buffer.search(1)",
	?N => "buffer.search(-1)",
	?g => "buffer.goto_line",
	?i => "buffer.toggle_editmode",
	?[ => "buffer.undo",
	?] => "buffer.redo",
	?{ => "buffer.revert_to_saved",
	?} => "buffer.unrevert_to_saved",
	?K => "buffer.screen_up",
	?J => "buffer.screen_down",
	?H => "buffer.screen_left",
	?L => "buffer.screen_right",
	?: => "buffer.enter_command"
}
$viewmode_commandlist.default = ""
$togglelist_array = [
	[?e, ["@editmode = true","Edit mode","ed"]],
	[?v, ["@editmode = false","View mode","vu"]],
	[?a, ["@autoindent = true","Autoindent","ai"]],
	[?m, ["@autoindent = false","Manual indent","mi"]],
	[?i, ["@insertmode = true","Insert mode","ins"]],
	[?o, ["@insertmode = false","Overwrite mode","ovrw"]],
	[?w, ["@linewrap = true","Line wrapping enabled","wrap"]],
	[?l, ["@linewrap = false","Line wrapping disabled","long"]],
	[?c, ["@colmode = true","Column mode","col"]],
	[?r, ["@colmode = false","Row mode","row"]],
	[?s, ["@syntax_color = true","Syntax color enabled","scol"]],
	[?b, ["@syntax_color = false","Syntax color disabled","bw"]]
]
$togglelist = Hash[$togglelist_array]
$togglelist.default = ["","Unknown toggle",""]








# -------------------------------------------------------
# -------------------------------------------------------
# --------------------- main code -----------------------
# -------------------------------------------------------
# -------------------------------------------------------


$hist_file = nil
optparse = OptionParser.new{|opts|
	opts.banner = "Usage: editor [options] file1 file2 ..."
	opts.on('-s', '--script FILE', 'Run this script at startup'){|file|
		run_script(file)
	}
	opts.on('-h', '--help', 'Display this screen'){
		puts opts
		exit
	}
	opts.on('-t', '--tabsize N', 'Set tabsize'){|n|
		$tabsize = n.to_i
	}
	opts.on('-a', '--autoindent', 'Turn on autoindent'){
		$autoindent = true
	}
	opts.on('-y', '--save-hist FILE', 'Save history in this file'){|file|
		$hist_file = file
	}
	opts.on('-v', '--view', 'Start in view mode'){
		$editmode = false
	}
	opts.on('-m', '--manualindent', 'Turn off autoindent'){
		$autoindent = false
	}
	opts.on('-w', '--linewrap', 'Turn on linewrap'){
		$linewrap = true
	}
	opts.on('-l', '--longlines', 'Turn off linewrap'){
		$linewrap = false
	}
	opts.on('-c', '--color', 'Turn on syntax coloring'){
		$syntax_color = true
	}
	opts.on('-b', '--nocolor', 'Turn off syntax coloring'){
		$syntax_color = false
	}
}
optparse.parse!



# store up search history
$search_hist = [""]
$replace_hist = [""]
$indent_hist = [""]
$lineno_hist = [""]
$command_hist = [""]
$scriptfile_hist = [""]
$script_hist = [""]

# read specified files into buffers of buffer list
$buffers = BuffersList.new(ARGV)

# copy buffer
$copy_buffer = ""

# for detecting changes to display
$screen_buffer = []


# initialize curses screen and run with it
$screen = Screen.new
$screen.init_screen do

	# this is the main action loop
	loop do

		# allow for resizes
		$screen.update_screen_size
		$cols = $screen.cols
		$rows = $screen.rows

		# make sure we are on the current buffer
		buffer = $buffers.current

		# take a snapshot of the buffer text,
		# for undo/redo purposes
		if buffer.buffer_history.text != buffer.text
			buffer.buffer_history.add(buffer.text)
		end

		# display the current buffer
		buffer.dump_to_screen($screen)

		# wait for a key press
		c = Curses.getch
		if c.is_a?(String) then c = c.unpack('C')[0] end

		# process key press -- run associated command
		if buffer.extramode
			eval($extramode_commandlist[c])
			buffer.extramode = false
			$screen.write_message("")
		else
			eval($commandlist[c])
			if buffer.editmode
				eval($editmode_commandlist[c])
				case c
					when 32..127 then buffer.addchar(c)
				end
			else
				eval($viewmode_commandlist[c])
			end
		end

		buffer.sanitize

	end
	# end of main action loop

end
