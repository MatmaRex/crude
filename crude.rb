require 'ruby_parser'
require 'pp'


$stuffs = Hash.new{|h,k| h[k] = {} }

def curlify text
	text += ";" unless text=~/\s*[\};]\Z/ or text=~/\A#/ or text=~/\A\s*\Z/
	"{\n#{text.gsub(/^/, '  ')}\n}\n"
end

def get_tmp_var_name
	if $stuffs[:last_tmp] == {}
		$stuffs[:last_tmp] = 100
	end
	
	$stuffs[:last_tmp] += 1
	
	'_' + $stuffs[:last_tmp].to_s
end

class Array
	def to_c
		type, *rest = *self
		this = rest[0] if rest.length==1
		
		case type
		when :call, :attrasgn
			receiver, name, arglist = *rest
			arguments = arglist[1..-1]
			
			if !receiver
				case name
				# "syntax"
				when :include
					arguments.map{|a| "#include <#{a[1]}>"}.join("\n")
				when :using_namespace
					arguments.map{|a| "using namespace #{a[1]}"}.join(";\n")
				when :defn
					_, fun_name, hsh = *arglist
					$stuffs[:function_sigs][fun_name[1] ] = {:from=>hsh[1], :to=>hsh[2]}
					''
				# convenience, methods requiring references - TODO: FIXME
				when :scanf
					# HORRIBLE HACK used to prevent prepending & to first arg
					"#{name}(#{arguments.map{|a| a.to_c.to_s}.join ', &'})"
					
				else
					"#{name}(#{arglist.to_c})"
				end
				
			else
				if name.to_s !~ /\w/ # it's an operator, buddy.
					name = name.to_s
					
					if name.length == 1 or (name.length==2 and name[-1] == '=')
						"(#{receiver.to_c} #{name} #{arguments.map(&:to_c).join(', ')})"
					elsif name=='-@' || name=='+@'
						"(#{name[0...-1]}#{receiver.to_c})"
					elsif name=='[]'
						"#{receiver.to_c}[#{arguments.map(&:to_c).join(', ')}]"
					elsif name=='[]='
						"#{receiver.to_c}[#{arguments.shift.to_c}] = #{arguments.map(&:to_c).join(', ')}"
					else
						raise "call: unsupported operator #{name}"
					end
				else # assume people know what they're doing
					"#{receiver.to_c}.#{name}(#{arguments.map(&:to_c).join(', ')})"
				end
			end
			
		when :arglist
			out = rest.map(&:to_c).join ', '
			# p rest, out
			out
		
		when :defn
			fun_name, args, body = *rest
			args = args[1..-1]
			
			to = $stuffs[:function_sigs][fun_name][:to]
			if to == [:nil]
				ret_type = 'void'
			else
				ret_type = to[1].to_s
			end
			
			from = $stuffs[:function_sigs][fun_name][:from]
			if from == [:nil]
				args_types = []
			elsif from[0] == :array
				args_types = from[1..-1].map{|sl| sl[1].to_s}
			else
				args_types = from.each_slice(2).map{|sl| sl[1].to_s}
			end
			
			
			sig = "#{ret_type} #{fun_name}(#{args_types.zip(args).map{|pair| pair.join ' '}.join(', ')})"
			fun_body = body.to_c
			
			
			"#{sig}\n#{curlify fun_body}"
		
		when :lasgn
			name, value = *rest
			prepend = ''
			
			type = 'no_idea'
			after_modifiers = ''
			before_modifiers = ''
			
			case value[0]
			when :lasgn # multiassignment
				# we do it the other way around, so we can get the type 
				# of the other variable, if it's being declared right now too
				prepend = value.to_c + ";\n"
				type = $stuffs[:var_types][value[1] ]
				value = value[1]
			when :lit
				type = value[1].to_c_type
				value = value[1]
			when :str
				type = 'char'
				if value[1].length != 1
					after_modifiers = '[]'
					value = value[1].inspect
				else
					value = "'" + value[1].inspect[1..-2].gsub(/'/, "\\'") + "'" # TODO: i'm pretty sure this is broken
				end
			when :lvar
				type = $stuffs[:var_types][value[1] ]
				value = value[1]
			when :call
				if value[2] and value[2] == :Array
					arguments = value[3][1..-1]
					size = arguments[0][1] # must be an int
					if arguments[1][0] == :call and arguments[1][2] == :Array
						# nested arrays
						# TODO: FIXME, recurse the fucker
						after_modifiers = "[#{size}]"
						
						arguments = arguments[1][3][1..-1]
						
						size = arguments[0][1] # must be an int
						after_modifiers += "[#{size}]"
						
						default = arguments[1]
						type = case default[0]
						when :lit;           default[1].to_c_type
						when :str;           'char'
						when :true, :false;  'bool'
						end
						value = "{#{arguments[1].to_c}}/**/" # a brace might prevent semicolon insertion
						
					else
						default = arguments[1]
						type = case default[0]
						when :lit;           default[1].to_c_type
						when :str;           'char'
						when :true, :false;  'bool'
						end
						after_modifiers = "[#{size}]"
						value = "{#{arguments[1].to_c}}/**/" # a brace might prevent semicolon insertion
					end
					
				else
					type = '/*assumed*/ int'
					value = value.to_c
				end
			when :not
				type = 'bool'
				value = value.to_c
			when :true, :false
				type = 'bool'
				value = value[0].to_s
			else
				raise "lasgn: unsupported value type `#{value[0]}` / #{value.inspect}"
			end
			
			if $stuffs[:var_types][name]
				prepend + "#{name} = #{value}"
			else
				$stuffs[:var_types][name] = type
				prepend + "#{type} #{before_modifiers}#{name}#{after_modifiers} = #{value}"
			end
			
		when :if
			condition, iftrue, iffalse = *rest
			
			ret = "if(#{condition.to_c})\n#{iftrue ? (curlify iftrue.to_c) : "{}\n"}"
			ret += "else\n#{curlify iffalse.to_c}" if iffalse
			ret
		
		when :iter
			fun_call, vars, body = *rest
			if !vars
				# pass - temporary name will be constructed later
			elsif vars and vars[0] == :lasgn
				iter_var_name = vars[1].to_s
			else
				raise "iter: unsupported variable assignment #{vars.inspect}"
			end
			
			_, receiver, meth, arglist = *fun_call
			case meth
			# TODO: fixme
			when :times
				iter_var_name ||= get_tmp_var_name()
				$stuffs[:var_types][iter_var_name.to_sym] = 'int'
				ret = "for(int #{iter_var_name}=0; #{iter_var_name}<#{receiver.to_c}; #{iter_var_name}++)\n"
				ret += body ? (curlify body.to_c) : '{}'
				$stuffs[:var_types][iter_var_name.to_sym] = nil # the variable is out of scope now
				ret
			when :upto
				iter_var_name ||= get_tmp_var_name()
				$stuffs[:var_types][iter_var_name.to_sym] = 'int'
				ret = "for(int #{iter_var_name}=#{receiver.to_c}; #{iter_var_name}<=#{arglist[1].to_c}; #{iter_var_name}++)\n"
				ret += body ? (curlify body.to_c) : '{}'
				$stuffs[:var_types][iter_var_name.to_sym] = nil # the variable is out of scope now
				ret
			when :downto
				iter_var_name ||= get_tmp_var_name()
				$stuffs[:var_types][iter_var_name.to_sym] = 'int'
				ret = "for(int #{iter_var_name}=#{receiver.to_c}; #{iter_var_name}>=#{arglist[1].to_c}; #{iter_var_name}--)\n"
				ret += body ? (curlify body.to_c) : '{}'
				$stuffs[:var_types][iter_var_name.to_sym] = nil # the variable is out of scope now
				ret
			else
				raise "iter: unsupported block given for method `#{meth}`"
			end
			
		when :lit
			case this
			when Numeric
				this.to_s
			when Symbol
				$stuffs[:symbols][this] ||= $stuffs[:symbols].length + 1
				this.to_s
			end
		
		when :str # assume all single-char strings to be chars, not char arrays
			if this.length != 1
				this.inspect
			else
				"'" + this.inspect[1..-2].gsub(/'/, "\\'") + "'" # TODO: i'm pretty sure this is broken
			end
			
		when :not
			"!(#{this.to_c})"
			
		when :and
			"((#{rest[0].to_c}) && (#{rest[1].to_c}))"
		when :or
			"((#{rest[0].to_c}) || (#{rest[1].to_c}))"
			
		when :return
			"return #{rest[0].to_c};"
		when :break
			"break;"
		when :next
			"continue;"
		
		when :lvar
			this
			
		when :block, :scope
			rest.map{|a|
				r = a.to_c.to_s.strip
				r += ";" unless r=~/\s*[\};]\Z/ or r=~/\A#/ or r=~/\A\s*\Z/
				r
			}.join("\n")
		
		when :true, :false
			type
		when :nil
			'null'
		
		else
			raise "unsupported node type `#{type}` / #{rest.inspect}"
		end
	end
	
	
end


class Fixnum; def to_c_type; 'int';   end; end
class Float;  def to_c_type; 'float'; end; end
class Symbol; def to_c_type; 'int';   end; end
class String; def to_c_type; 'char';  end; end


parsed = RubyParser.new.parse File.read ARGV[0]
puts parsed.to_a.to_c

# TODO: symbols as constants
# pp $stuffs
