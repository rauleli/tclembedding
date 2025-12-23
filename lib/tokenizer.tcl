package require json

package provide tclembedding::tokenizer 1.0.0

namespace eval tokenizer {
    variable vocab
    variable unk_id 1  ;# Default usual, se sobreescribe al cargar
    variable bos_id 0
    variable eos_id 2

    proc load_vocab {json_path} {
        variable vocab
        variable unk_id
        variable bos_id
        variable eos_id

        set fp [open $json_path r]
        set content [read $fp]
        close $fp
        
        puts "📖 Tokenizer TCL: Leyendo JSON..."
        set data [json::json2dict $content]
        
        set raw_vocab ""
        if {[dict exists $data model vocab]} {
            set raw_vocab [dict get $data model vocab]
        } elseif {[dict exists $data vocab]} {
            set raw_vocab [dict get $data vocab]
        } else {
            error "No se encontró el objeto 'vocab' en el JSON"
        }

        # --- DETECCIÓN DE FORMATO ---
        # Caso A: Lista de Listas (SentencePiece / Xenova) -> [["<s>", 0.0], ["pad", 0.0]]
        # Caso B: Diccionario plano (BERT) -> {"<s>": 0, "pad": 1}
        
        set vocab [dict create]
        set first_item [lindex $raw_vocab 0]
        
        if {[llength $first_item] > 1} {
            puts "   Detected Format: SentencePiece Array (Index = ID)"
            set idx 0
            foreach item $raw_vocab {
                # El token es el primer elemento de la sublista
                set token [lindex $item 0]
                dict set vocab $token $idx
                
                # Detectar IDs especiales al vuelo
                if {$token eq "<unk>"} { set unk_id $idx }
                if {$token eq "<s>"}   { set bos_id $idx }
                if {$token eq "</s>"}  { set eos_id $idx }
                
                incr idx
            }
        } else {
            puts "   Detected Format: Flat Dictionary (Key = Token, Val = ID)"
            set vocab $raw_vocab
            # Intentar buscar unk explícito si es dict
            if {[dict exists $vocab "<unk>"]} { set unk_id [dict get $vocab "<unk>"] }
        }
        
        puts "✅ Vocabulario cargado: [dict size $vocab] tokens."
        puts "   Special Tokens -> BOS: $bos_id | EOS: $eos_id | UNK: $unk_id"
    }

    proc tokenize {text} {
        variable vocab
        variable unk_id
        variable bos_id
        variable eos_id

        # 1. Normalización SentencePiece: Espacios -> U+2581 (  )
        # Reemplazamos espacio normal por el "Lower One Eighth Block"
        set normalized [string map {" " "\u2581"} $text]
        
        # SentencePiece suele requerir el prefijo de espacio al inicio si no es el comienzo de linea puro
        if {[string index $normalized 0] ne "\u2581"} {
            set normalized "\u2581$normalized"
        }
        
        # 2. Greedy Longest-Match
        set tokens [list $bos_id]
        set len [string length $normalized]
        set i 0
        
        # Optimizaciones de bucle
        while {$i < $len} {
            set match_found 0
            # Ventana de búsqueda (max 25 caracteres para eficiencia)
            set max_w [expr {min($len, $i + 25)}]
            
            for {set j $max_w} {$j > $i} {incr j -1} {
                set sub [string range $normalized $i [expr {$j - 1}]]
                if {[dict exists $vocab $sub]} {
                    lappend tokens [dict get $vocab $sub]
                    set i $j
                    set match_found 1
                    break
                }
            }
            
            if {!$match_found} {
                # Si no encuentra match, probamos caracter individual por si acaso
                set char [string range $normalized $i $i]
                if {[dict exists $vocab $char]} {
                    lappend tokens [dict get $vocab $char]
                } else {
                    lappend tokens $unk_id
                }
                incr i
            }
        }
        
        lappend tokens $eos_id
        return $tokens
    }
}
