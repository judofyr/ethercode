# NOTE: This is a one-day hack :-)

require 'camping'
require 'albino'
require 'json'
require 'bcat'
require './friendly'

Camping.goes :Ethercode

module Ethercode
  use Rack::Chunked

  def to_a
    @headers["Content-Type"] ||= 'text/html'
    @body = [@body] if @body.respond_to?(:to_str)
    [@status, @headers, @body]
  end
end

module Ethercode::Models
  class Runner
    attr_reader :status

    def initialize(code)
      @r, @w = IO.pipe
      @r.sync = true
      @w.sync = true
      @code = code
    end

    def run
      @pid = fork do
        ARGV.clear
        $0 = '(ethercode)'
        STDOUT.reopen(@w)
        STDERR.reopen(@w)
        eval(@code, TOPLEVEL_BINDING, $0, 1)
      end

      @w.close
      self
    end

    def each
      while !@r.eof?
        yield @r.gets
      end
      Process.wait(@pid)
      yield "Done: #{$?}"
    end
  end
end

module Ethercode::Helpers
  def syntax_errors_for(code)
    catch(:ok) do
      eval("BEGIN{throw :ok}\n#{code}")
    end
    nil
  rescue SyntaxError
    [$!.message[/:(\d+):/, 1].to_i - 1, *$!.friendly]
  end

  def highlight(code, valid = true)
    if valid
      Albino.colorize(code, :ruby)
    else
      Albino.colorize(code)
    end
  end

  class Wrapper
    def initialize(input) @input = input end

    def each(&blk)
      yield "\n" * 1000
      yield '<!DOCTYPE html><link rel="stylesheet" href="/style.css"><body><div id="output">'
      @input.each do |str|
        yield str
      end
      yield '<script>parent.info("Done")</script></div></body></html>'
    end
  end
end

module Ethercode::Controllers
  class Index
    def get
      render :bookmarklet
    end
  end

  class Presenter
    def get
      render :index
    end
  end

  class Run
    def get
      return '' unless $code
      runner = Runner.new($code).run
      runner = Bcat::TextFilter.new(runner)
      runner = Bcat::ANSI.new(runner)
      runner = Wrapper.new(runner)
      runner
    ensure
      $code = nil
    end

    def post
      code = @input.code.gsub(/\r/, '').gsub(/^(    )+/) { |m| " " * (m.size / 2) }
      err = syntax_errors_for(code)
      $code = code unless err
      pre = highlight(code, !err)

      args = ['code']
      args.concat(err.map(&:to_json)) if err

      return <<-HTML
        <div id="code">#{pre}</div>
        <script>window.parent.ethercode.run(#{args * ', '})</script>
      HTML
    end
  end

  class Style < R '/style.css'
    CSS = File.read(__FILE__).match(/^__END__\n/).post_match
    
    def get
      @headers['Content-Type'] = 'text/css'
      CSS
    end
  end
end

module Ethercode::Views
  def index
    link :rel => 'stylesheet', :href => R(Style)
    body do

      div.wrapper! do
        div.error! ""
        div.show! ""
      end

      div.infobar! "Waiting..."
      iframe "",:src => R(Run), :id => 'runner'

      script do
        <<-JS
        var i;
        var t;

        window.onresize = function() {
          var height = innerHeight;
          height -= infobar.clientHeight + 1;
          document.getElementById('runner').style.height = height + 'px';
        };

        window.onresize();

        function info(str) {
          infobar.innerHTML = str;
        }

        function run(code, err) {
          show.innerHTML = '';
          show.appendChild(code);
          t && clearTimeout(t);
          i = 3;

          if (err !== undefined) {
            error.style.display = 'block';
            info("Syntax error!");
            var xtra = Array.prototype.slice.call(arguments, 2);
            error.innerHTML = xtra.join('<br>');
            error.style.marginTop = (err * 1.2) + 'em';
          } else {
            error.style.display = 'none';
            runner.document.body.innerHTML = '';
            timeout();
          }
        };

        function timeout() {
          if (i) {
            info("Running in " + i + " seconds..");
            i -= 1;
            t = setTimeout(timeout, 1000);
          } else {
            t = null;
            info("Running...");
            runner.location.reload();
          }

        };
        JS
      end
    end
  end

  def bookmarklet
    a "Bookmarklet", :href => <<-JS.lstrip, :title => 'Ethercode'
      javascript:void((function(d,i,e,r){var m=padeditor.ace.applyChangesToBase;padeditor.ace.applyChangesToBase=function(){
        m.apply(this, arguments);
        d.body.appendChild(i = d.createElement('iframe'));
        setTimeout((function(a) { return function() { d.body.removeChild(a) } })(i), 3000);
        e=i.contentWindow.document;
        e.write('<form action="#{URL(Run)}" id="run" method="post"><textarea name="code"></textarea></form>');
        r=e.getElementById('run');
        r.childNodes[0].value = this.exportText();
        r.submit();
      };
      i=d.createElement('iframe');
      i.src = "#{URL(Presenter)}";
      i.name = "ethercode";
      i.setAttribute('style', "width:100%;position:absolute;top:0;height:100%;z-index:99999;border:0");
      d.body.appendChild(i);
      d.body.setAttribute('style', "overflow:hidden");
      })(document));
    JS
  end
end

__END__
* { margin:0;padding:0 }

body,pre {
  background: #222222; color: #f8f8f2;
  line-height: 1.2;
  font-size: 16px;
  font-family: Menlo, monospace;
}

#infobar {
  background-color: #333;
  float: right;
  font-style: italic;
  padding: 0.5em 10px;
  width: 780px;
}

#wrapper {
  padding-right: 800px;
  position: relative;
}

#error {
  background: black;
  display: none;
  position: absolute;
  border: 3px solid red;
  border-radius: 3px;
  padding: 3px;
  left: 8px;
  top: 12px;
}

#show {
  float: left;
  height: 100%;
  overflow: auto;
  width: 100%;
}

#runner {
  border: 0;
  float: right;
  height: 100%;
  overflow: auto;
  width: 800px;
}

.highlight, #output { padding: 10px }
.highlight .hll { background-color: #49483e }
.highlight .c { color: #75715e } /* Comment */
.highlight .err { color: #960050; background-color: #1e0010 } /* Error */
.highlight .k { color: #66d9ef } /* Keyword */
.highlight .l { color: #ae81ff } /* Literal */
.highlight .n { color: #f8f8f2 } /* Name */
.highlight .o { color: #f92672 } /* Operator */
.highlight .p { color: #f8f8f2 } /* Punctuation */
.highlight .cm { color: #75715e } /* Comment.Multiline */
.highlight .cp { color: #75715e } /* Comment.Preproc */
.highlight .c1 { color: #75715e } /* Comment.Single */
.highlight .cs { color: #75715e } /* Comment.Special */
.highlight .ge { font-style: italic } /* Generic.Emph */
.highlight .gs { font-weight: bold } /* Generic.Strong */
.highlight .kc { color: #66d9ef } /* Keyword.Constant */
.highlight .kd { color: #66d9ef } /* Keyword.Declaration */
.highlight .kn { color: #f92672 } /* Keyword.Namespace */
.highlight .kp { color: #66d9ef } /* Keyword.Pseudo */
.highlight .kr { color: #66d9ef } /* Keyword.Reserved */
.highlight .kt { color: #66d9ef } /* Keyword.Type */
.highlight .ld { color: #e6db74 } /* Literal.Date */
.highlight .m { color: #ae81ff } /* Literal.Number */
.highlight .s { color: #e6db74 } /* Literal.String */
.highlight .na { color: #a6e22e } /* Name.Attribute */
.highlight .nb { color: #f8f8f2 } /* Name.Builtin */
.highlight .nc { color: #a6e22e } /* Name.Class */
.highlight .no { color: #66d9ef } /* Name.Constant */
.highlight .nd { color: #a6e22e } /* Name.Decorator */
.highlight .ni { color: #f8f8f2 } /* Name.Entity */
.highlight .ne { color: #a6e22e } /* Name.Exception */
.highlight .nf { color: #a6e22e } /* Name.Function */
.highlight .nl { color: #f8f8f2 } /* Name.Label */
.highlight .nn { color: #f8f8f2 } /* Name.Namespace */
.highlight .nx { color: #a6e22e } /* Name.Other */
.highlight .py { color: #f8f8f2 } /* Name.Property */
.highlight .nt { color: #f92672 } /* Name.Tag */
.highlight .nv { color: #f8f8f2 } /* Name.Variable */
.highlight .ow { color: #f92672 } /* Operator.Word */
.highlight .w { color: #f8f8f2 } /* Text.Whitespace */
.highlight .mf { color: #ae81ff } /* Literal.Number.Float */
.highlight .mh { color: #ae81ff } /* Literal.Number.Hex */
.highlight .mi { color: #ae81ff } /* Literal.Number.Integer */
.highlight .mo { color: #ae81ff } /* Literal.Number.Oct */
.highlight .sb { color: #e6db74 } /* Literal.String.Backtick */
.highlight .sc { color: #e6db74 } /* Literal.String.Char */
.highlight .sd { color: #e6db74 } /* Literal.String.Doc */
.highlight .s2 { color: #e6db74 } /* Literal.String.Double */
.highlight .se { color: #ae81ff } /* Literal.String.Escape */
.highlight .sh { color: #e6db74 } /* Literal.String.Heredoc */
.highlight .si { color: #e6db74 } /* Literal.String.Interpol */
.highlight .sx { color: #e6db74 } /* Literal.String.Other */
.highlight .sr { color: #e6db74 } /* Literal.String.Regex */
.highlight .s1 { color: #e6db74 } /* Literal.String.Single */
.highlight .ss { color: #e6db74 } /* Literal.String.Symbol */
.highlight .bp { color: #f8f8f2 } /* Name.Builtin.Pseudo */
.highlight .vc { color: #f8f8f2 } /* Name.Variable.Class */
.highlight .vg { color: #f8f8f2 } /* Name.Variable.Global */
.highlight .vi { color: #f8f8f2 } /* Name.Variable.Instance */
.highlight .il { color: #ae81ff } /* Literal.Number.Integer.Long */

@-webkit-keyframes blinker {
  from { opacity: 1.0; }
  to { opacity: 0.0; }
}

blink {
  -webkit-animation-name: blinker;
  -webkit-animation-iteration-count: infinite;
  -webkit-animation-timing-function: cubic-bezier(1.0,0,0,1.0);
  -webkit-animation-duration: 1s;
}



