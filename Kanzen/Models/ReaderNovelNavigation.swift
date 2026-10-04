import Foundation

#if !os(tvOS)
enum ReaderNovelReadingMode: String, CaseIterable {
    case scroll
    case paged

    var title: String { self == .scroll ? "Scrolling" : "Pages" }
}

enum ReaderNovelPreferences {
    static let modeKey = "readerNovelReadingMode"
    static let fonts = ["-apple-system", "Georgia", "Times New Roman", "Helvetica", "Charter", "New York", "ui-rounded", "Menlo", "serif", "sans-serif"]
    static let weights = ["300", "normal", "500", "600", "700", "bold"]
    static let alignments = ["left", "center", "right", "justify"]

    static func font(_ value: String) -> String { fonts.contains(value) ? value : "-apple-system" }
    static func weight(_ value: String) -> String { weights.contains(value) ? value : "normal" }
    static func alignment(_ value: String) -> String { alignments.contains(value) ? value : "left" }
    static func fraction(_ value: Double) -> Double { value.isFinite ? min(max(value, 0), 1) : 0 }
}

struct ReaderNovelLocator: Codable, Equatable, Sendable {
    var textIndex: Int
    var offset: Int
    var quote: String
    var fraction: Double

    var isValid: Bool {
        (0...100_000).contains(textIndex) && (0...4_194_304).contains(offset)
            && quote.utf8.count <= 512 && fraction.isFinite && (0...1).contains(fraction)
    }

    static func decode(_ data: Data?) -> ReaderNovelLocator? {
        guard let data, data.count <= 2_048, let locator = try? JSONDecoder().decode(Self.self, from: data), locator.isValid else { return nil }
        return locator
    }
}

struct ReaderNovelBookmark: Codable, Equatable, Identifiable, Sendable {
    var id: UUID
    var chapterKey: String
    var chapterTitle: String
    var locator: ReaderNovelLocator

    static let maximumCount = 200

    static func decode(_ data: Data?) -> [ReaderNovelBookmark] {
        guard let data, data.count <= 512 * 1_024,
              let values = try? JSONDecoder().decode([Self].self, from: data), values.count <= maximumCount else { return [] }
        var seen = Set<UUID>()
        return values.filter {
            !$0.chapterKey.isEmpty && $0.chapterKey.utf8.count <= 4_096
                && $0.chapterTitle.utf8.count <= 1_024 && $0.locator.isValid && seen.insert($0.id).inserted
        }
    }
}

enum ReaderNovelScripts {
    static func literal<T: Encodable>(_ value: T) -> String {
        guard let bytes = try? JSONEncoder().encode(value), let string = String(data: bytes, encoding: .utf8) else { return "null" }
        return string
    }

    static let install = #"""
    (()=>{
      if(window.__eclipseNovelReader)return;
      const textNodes=[],walker=document.createTreeWalker(document.body,NodeFilter.SHOW_TEXT);while(walker.nextNode()){let n=walker.currentNode;if(n.nodeValue&&n.parentElement&&!n.parentElement.closest('script,style'))textNodes.push(n)}const locatorNodes=textNodes.filter(n=>n.nodeValue.trim()),nodes=()=>locatorNodes;
      const quote=n=>{let value=n.nodeValue.slice(0,128),last=value.charCodeAt(value.length-1);return last>=0xD800&&last<=0xDBFF?value.slice(0,-1):value};
      const paged=()=>document.documentElement.dataset.readerMode==='paged';
      const width=()=>Math.max(1,innerWidth);
      const extent=()=>Math.max(0,document.documentElement.scrollHeight-innerHeight);
      const fraction=()=>paged()?Math.max(0,scrollX)/Math.max(1,document.documentElement.scrollWidth-width()):Math.max(0,scrollY)/Math.max(1,extent());
      const locate=()=>{let ns=nodes(),r=document.caretRangeFromPoint(Math.min(80,innerWidth/2),Math.min(80,innerHeight/3)),i=r?ns.indexOf(r.startContainer):-1;if(i<0){i=ns.findIndex(n=>{let q=document.createRange();q.selectNodeContents(n);let b=q.getBoundingClientRect();return b.bottom>40&&b.right>0&&b.left<innerWidth});r=null}i=Math.max(0,i);let n=ns[i];return {textIndex:i,offset:r?r.startOffset:0,quote:n?quote(n):'',fraction:Math.min(1,fraction())}};
      const seekPosition=f=>{f=Math.min(1,Math.max(0,Number(f)||0));if(paged()){let pages=Math.max(1,Math.ceil(document.documentElement.scrollWidth/width()));scrollTo(Math.round(f*(pages-1))*width(),0)}else scrollTo(0,extent()*f)};
      const seek=f=>{seekPosition(f);settle()};
      const reveal=r=>{let b=r.getBoundingClientRect();if(paged()){scrollTo(Math.max(0,Math.floor((b.left+scrollX)/width()))*width(),0)}else scrollTo(0,scrollY+b.top-64)};
      const restore=(l,internal=false)=>{if(!l){seekPosition(0);if(internal)stablePosition=locate();else settle();return}let ns=nodes(),n=ns[l.textIndex];if(!n||quote(n)!==l.quote)n=ns.find(n=>quote(n)===l.quote);if(n){let r=document.createRange(),o=Math.min(n.nodeValue.length,Math.max(0,l.offset||0));r.setStart(n,o);r.setEnd(n,Math.min(n.nodeValue.length,o+1));reveal(r)}else seekPosition(l.fraction);if(internal)stablePosition=locate();else settle()};
      let matches=[],matchIndex=-1,lastQuery='',searchIndex=null;
      const index=()=>{if(searchIndex)return searchIndex;let text='',segments=[],previous=null;for(let n of textNodes){let block=n.parentElement.closest('p,div,li,h1,h2,h3,h4,h5,h6,td,th,pre,blockquote,figcaption,section,article');if(previous&&block!==previous)text+='\n';let start=text.length;text+=n.nodeValue;segments.push({n,start,end:text.length});previous=block}return searchIndex={text,segments}};
      const segmentAt=(segments,offset,end)=>{let low=0,high=segments.length-1;while(low<=high){let middle=(low+high)>>1,s=segments[middle];if(offset<s.start||(end&&offset===s.start))high=middle-1;else if(offset>s.end||(!end&&offset===s.end))low=middle+1;else return s}return null};
      const find=(query,direction)=>{query=String(query||'').slice(0,256);if(query!==lastQuery){lastQuery=query;matches=[];matchIndex=-1;if(query){let indexed=index(),re=new RegExp(query.replace(/[.*+?^${}()|[\]\\]/g,'\\$&'),'giu'),m;while((m=re.exec(indexed.text))&&matches.length<2000){let first=segmentAt(indexed.segments,m.index,false),last=segmentAt(indexed.segments,m.index+m[0].length,true);if(first&&last)matches.push({first,last,start:m.index-first.start,end:m.index+m[0].length-last.start})}}}if(!matches.length){getSelection().removeAllRanges();return {index:0,count:0}}matchIndex=matchIndex<0?(direction<0?matches.length-1:0):(matchIndex+(direction<0?-1:1)+matches.length)%matches.length;let m=matches[matchIndex],r=document.createRange();r.setStart(m.first.n,m.start);r.setEnd(m.last.n,m.end);let s=getSelection();s.removeAllRanges();s.addRange(r);reveal(r);settle();return {index:matchIndex+1,count:matches.length}};
      const page=direction=>{if(paged())scrollBy(direction*width(),0);else scrollBy(0,direction*Math.max(1,innerHeight-100));settle();return report()};
      const fragment=id=>{let el=document.getElementById(id);if(el){let r=document.createRange();r.selectNodeContents(el);reveal(r);settle();return true}return false};
      const report=()=>{let total=paged()?document.documentElement.scrollWidth:document.documentElement.scrollHeight,position=paged()?Math.max(0,scrollX)+width():Math.max(0,scrollY)+innerHeight;return {progress:Math.min(1,position/Math.max(1,total)),scrollPos:paged()?Math.min(1,fraction()):Math.max(0,scrollY)/Math.max(1,document.documentElement.scrollHeight),locator:locate(),page:paged()?Math.round(Math.max(0,scrollX)/width())+1:0,pages:paged()?Math.max(1,Math.ceil(total/width())):0}};
      window.__eclipseNovelReader={locate,restore,seek,find,page,fragment,report,version:()=>commandGeneration};
      let stablePosition=locate(),resizing=false,scrollFrame=false,commandGeneration=0;
      const settle=()=>{commandGeneration++;resizing=false;stablePosition=locate()};
      for(let event of ['pointerdown','touchstart','wheel'])addEventListener(event,e=>{if(e.isTrusted)settle()},{passive:true});
      addEventListener('scroll',()=>{if(resizing||scrollFrame)return;scrollFrame=true;requestAnimationFrame(()=>{scrollFrame=false;if(!resizing)stablePosition=locate()})},{passive:true});
      addEventListener('resize',()=>{let position=stablePosition,generation=commandGeneration;resizing=true;requestAnimationFrame(()=>{if(generation!==commandGeneration){resizing=false;return}if(position)restore(position,true);resizing=false;stablePosition=locate()})});
    })();
    """#
}
#endif
