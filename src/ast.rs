use std::collections::BTreeMap;

pub type Attr = (String, Vec<String>, Vec<(String, String)>);

pub fn null_attr() -> Attr {
    (String::new(), Vec::new(), Vec::new())
}

pub type Target = (String, String);

#[derive(Clone, Debug, PartialEq)]
pub struct Format(pub String);

pub type ListAttributes = (i64, ListNumberStyle, ListNumberDelim);

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ListNumberStyle {
    DefaultStyle,
    Example,
    Decimal,
    LowerRoman,
    UpperRoman,
    LowerAlpha,
    UpperAlpha,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ListNumberDelim {
    DefaultDelim,
    Period,
    OneParen,
    TwoParens,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum QuoteType {
    SingleQuote,
    DoubleQuote,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum MathType {
    DisplayMath,
    InlineMath,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Alignment {
    AlignLeft,
    AlignRight,
    AlignCenter,
    AlignDefault,
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub enum ColWidth {
    ColWidth(f64),
    ColWidthDefault,
}

pub type ColSpec = (Alignment, ColWidth);

#[derive(Clone, Debug, PartialEq)]
pub struct Row(pub Attr, pub Vec<Cell>);

#[derive(Clone, Debug, PartialEq)]
pub struct TableHead(pub Attr, pub Vec<Row>);

#[derive(Clone, Debug, PartialEq)]
pub struct TableBody(pub Attr, pub i64, pub Vec<Row>, pub Vec<Row>);

#[derive(Clone, Debug, PartialEq)]
pub struct TableFoot(pub Attr, pub Vec<Row>);

#[derive(Clone, Debug, PartialEq)]
pub struct Caption(pub Option<Vec<Inline>>, pub Vec<Block>);

#[derive(Clone, Debug, PartialEq)]
pub struct Cell(pub Attr, pub Alignment, pub i64, pub i64, pub Vec<Block>);

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum CitationMode {
    AuthorInText,
    SuppressAuthor,
    NormalCitation,
}

#[derive(Clone, Debug, PartialEq)]
pub struct Citation {
    pub citation_id: String,
    pub citation_prefix: Vec<Inline>,
    pub citation_suffix: Vec<Inline>,
    pub citation_mode: CitationMode,
    pub citation_note_num: i64,
    pub citation_hash: i64,
}

#[derive(Clone, Debug, PartialEq)]
pub enum MetaValue {
    MetaMap(BTreeMap<String, MetaValue>),
    MetaList(Vec<MetaValue>),
    MetaBool(bool),
    MetaString(String),
    MetaInlines(Vec<Inline>),
    MetaBlocks(Vec<Block>),
}

#[derive(Clone, Debug, Default, PartialEq)]
pub struct Meta(pub BTreeMap<String, MetaValue>);

#[derive(Clone, Debug, Default, PartialEq)]
pub struct Pandoc {
    pub meta: Meta,
    pub blocks: Vec<Block>,
}

#[derive(Clone, Debug, PartialEq)]
pub enum Block {
    Plain(Vec<Inline>),
    Para(Vec<Inline>),
    LineBlock(Vec<Vec<Inline>>),
    CodeBlock(Attr, String),
    RawBlock(Format, String),
    BlockQuote(Vec<Block>),
    OrderedList(ListAttributes, Vec<Vec<Block>>),
    BulletList(Vec<Vec<Block>>),
    DefinitionList(Vec<(Vec<Inline>, Vec<Vec<Block>>)>),
    Header(i64, Attr, Vec<Inline>),
    HorizontalRule,
    Table(
        Attr,
        Caption,
        Vec<ColSpec>,
        TableHead,
        Vec<TableBody>,
        TableFoot,
    ),
    Figure(Attr, Caption, Vec<Block>),
    Div(Attr, Vec<Block>),
}

#[derive(Clone, Debug, PartialEq)]
pub enum Inline {
    Str(String),
    Emph(Vec<Inline>),
    Underline(Vec<Inline>),
    Strong(Vec<Inline>),
    Strikeout(Vec<Inline>),
    Superscript(Vec<Inline>),
    Subscript(Vec<Inline>),
    SmallCaps(Vec<Inline>),
    Quoted(QuoteType, Vec<Inline>),
    Cite(Vec<Citation>, Vec<Inline>),
    Code(Attr, String),
    Space,
    SoftBreak,
    LineBreak,
    Math(MathType, String),
    RawInline(Format, String),
    Link(Attr, Vec<Inline>, Target),
    Image(Attr, Vec<Inline>, Target),
    Note(Vec<Block>),
    Span(Attr, Vec<Inline>),
}

impl Block {
    pub fn tag(&self) -> &'static str {
        match self {
            Block::Plain(_) => "Plain",
            Block::Para(_) => "Para",
            Block::LineBlock(_) => "LineBlock",
            Block::CodeBlock(..) => "CodeBlock",
            Block::RawBlock(..) => "RawBlock",
            Block::BlockQuote(_) => "BlockQuote",
            Block::OrderedList(..) => "OrderedList",
            Block::BulletList(_) => "BulletList",
            Block::DefinitionList(_) => "DefinitionList",
            Block::Header(..) => "Header",
            Block::HorizontalRule => "HorizontalRule",
            Block::Table(..) => "Table",
            Block::Figure(..) => "Figure",
            Block::Div(..) => "Div",
        }
    }
}

impl Inline {
    pub fn tag(&self) -> &'static str {
        match self {
            Inline::Str(_) => "Str",
            Inline::Emph(_) => "Emph",
            Inline::Underline(_) => "Underline",
            Inline::Strong(_) => "Strong",
            Inline::Strikeout(_) => "Strikeout",
            Inline::Superscript(_) => "Superscript",
            Inline::Subscript(_) => "Subscript",
            Inline::SmallCaps(_) => "SmallCaps",
            Inline::Quoted(..) => "Quoted",
            Inline::Cite(..) => "Cite",
            Inline::Code(..) => "Code",
            Inline::Space => "Space",
            Inline::SoftBreak => "SoftBreak",
            Inline::LineBreak => "LineBreak",
            Inline::Math(..) => "Math",
            Inline::RawInline(..) => "RawInline",
            Inline::Link(..) => "Link",
            Inline::Image(..) => "Image",
            Inline::Note(_) => "Note",
            Inline::Span(..) => "Span",
        }
    }
}

impl Meta {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn is_empty(&self) -> bool {
        self.0.is_empty()
    }
}
