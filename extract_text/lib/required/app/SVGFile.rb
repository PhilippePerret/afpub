# encoding: UTF-8
module AfPub
class SVGFile

  class FalseErrorNodeFind < StandardError; end

  attr_reader :path

  def initialize(path)
    @path = path
  end

  ##
  # = main =
  # 
  # Cette méthode retourne un texte complètement abouti, sur lequel
  # plus aucun travail de formatage n'est à faire. Normalement, il
  # est tel qu'il doit être dans le fichier texte.
  # 
  def extract_text
    # 
    # On prend d'abord le texte dans le fichier, tel qu'il semble
    # être affiché (donc avec quelques retours chariots inopportuns)
    # 
    texte = get_texte_brut
    if is_page_to_debug?
      ExtractedFile.save_in_file_debug("texte_brut", texte)
    end
    
    # 
    # On envoie ce texte en traitement, pour qu'il soit parfaitement
    # abouti et puisse être retourné.
    # 
    texte_fini = TextAffinator.affine(texte)

    ExtractedFile.save_in_file_debug("texte_affined", texte_fini)

    return texte_fini
  end

  ##
  # EXTRACTION DU TEXTE DU FICHIER
  # ------------------------------
  # 
  # Deuxième version de l'extraction, très simplifiée, sans passer
  # par toutes les instances (qui prennent beaucoup de place pour 
  # rien)
  # 
  # La méthode retourne le texte tel qu'il a pu être récupérer dans
  # le fichier, pour le moment sans correction sur le texte lui-même.
  # Donc on se retrouve encore avec des textes qui peuvent être à la
  # ligne alors qu'ils doivent s'écrire en une phrase :
  # ON A ÇA :
  #     Ceci est une première phrase
  #     qui continue ici.
  # AU LIEU DE ÇA :
  #     Ceci est une première phrase qui continue ici.
  # Ce sera corrigé ensuite.
  # 
  def get_texte_brut
    # 
    # Nouvelle extraction, en simplifiant la relève.
    # On ne prend plus des nœuds, on extrait tout de suite leur
    # contenu et leur x/y
    # 

    # 
    # Pour mettre tous les "groupes" de textes (même lorsqu'un 
    # texte est hors-groupe — hors <g> — il est mis dans un groupe)
    # Un groupe (un élément de +groupes+ est un groupe de textes)
    # 
    groupes = []

    xdoc = Nokogiri::XML(File.read(path))
    xdoc.css('svg > text, svg > g').each_with_index do |node, idx|
      if node.name == "text" # texte de premier niveau
        # 
        # Un texte de premier niveau
        # 
        # On fait comme s'il était dans un groupe, pour correspondre
        # avec la balise <g>. Mais attention, on peut avoir plusieurs
        # paragraphes dans un groupe, ça n'est pas un paragraphe
        # 
        xnode = sanpx(node['x'])
        ynode = sanpx(node['y'])
        txt = {index: idx, text:node.content, x:xnode, y:ynode}
        verbose? && puts(" T-NODE ##{idx} x:#{xnode.to_s.ljust(6)} y:#{ynode.to_s.ljust(6)} #{node.content}")
      
        # 
        # Un groupe isolé
        # 
        groupes << {
          index: idx, 
          texts:[txt], 
          x:xnode, 
          y:ynode, 
          xr:xnode, 
          yr:ynode, 
          ymin:ynode, 
          ymax:ynode
        }
      
      elsif node.name == "g"
        # 
        # Un groupe <g>
        # 
        # Les textes dans un groupe sont forcément ensemble, ils ne
        # peuvent pas être déplacés
        # 
        gnode = " G-NODE ##{idx}"
        groupe = {index:idx, texts:[], x:1000000, y:1000000, xmin:1000000, ymin:1000000, xmax:0, ymax:0}
        matrice = nil
        if node.has_attribute?('x')
          # puts "Il a des attributs".blue
          gnode = gnode + " x:#{sanpxl(node.attr('x'))} y:#{sanpxl(nodeattr('y'))}"
        elsif node.has_attribute?('transform')
          # 
          # Si le groupe possède un attribut 'transform', c'est qu'il
          # est placé autre part que l'endroit auquel on pense. On
          # doit chercher où 
          # 
          matrice = get_matrix_in(node.attr('transform'))
        end
        verbose? && puts(gnode)
        node.css('text').each_with_index do |cnode, cidx|
          xcnode = sanpx(cnode['x'])
          ycnode = sanpx(cnode['y'])
          groupe[:texts] << {idx:cidx, text:cnode.text, x:xcnode, y:ycnode}
          verbose? && puts("ST-NODE ##{cidx} x:#{xcnode.to_s.ljust(6)} y:#{ycnode.to_s.ljust(6)} #{cnode.text}")
          #
          # Si le x de ce texte est plus petit que le x du groupe,
          # on le prend en x (pour avoir le plus petit)
          #
          if xcnode < groupe[:xmin]
            groupe[:x]    = xcnode
            groupe[:xmin] = xcnode
          end
          if xcnode > groupe[:xmax]
            groupe[:xmax] = xcnode
          end
          # Idem pour y
          if ycnode < groupe[:y]
            groupe[:y]    = ycnode
            groupe[:ymin] = ycnode 
          end
          if ycnode > groupe[:ymax]
            groupe[:ymax] = ycnode
          end
        end

        # 
        # On ajoute ce groupe de textes aux groupes, mais seulement
        # s'il a des textes
        # 
        if groupe[:texts].any?
          # 
          # On rectifie les coordonnées x, y du groupe en fonction
          # de la matrice de transformation si elle était définie
          # dans la balise <g>
          # La valeur actuelle (non matricée, définie par le texte
          # le plus en haut du groupe) définit la valeur non matricée.
          # C'est :x et :y ici. La valeur matricée, c'est-à-dire 
          # rectifiée pour correspondre à la réalité est en :xm et
          # ym.
          # DONC :  ym - y  => différence d'y (à ajouter)
          #         xm - x  => différence de x (à ajouter)
          if matrice
            xr, yr  = [ groupe[:x], groupe[:y] ]
            x, y    = transforme_by_matrix(xr, yr, matrice)
            groupe.merge!(x: x, y:y, xr:xr, yr:yr)
            xdiff = x - xr
            ydiff = y - yr
            groupe[:xmin] += xdiff
            groupe[:xmax] += xdiff
            groupe[:ymin] += ydiff
            groupe[:ymax] += ydiff
            # 
            # On ajoute cette différence matricielle à toutes les
            # valeur des textes du groupe
            # 
            groupe[:texts].each do |dtexte|
              dtexte.merge!(
                xr: dtexte[:x],
                x:  dtexte[:x] + xdiff,
                yr: dtexte[:y],
                y:  dtexte[:y] + ydiff
              )
            end
          end
          # puts "-groupe: #{groupe.inspect}"
          # 
          # On peut ajouter ce groupe, maintenant
          # 
          groupes << groupe 
        end

      else
        
        raise "Aucun raison de trouver un node <#{node.name}>…"
        
      end
    end

    if is_page_to_debug?
      ExtractedFile.save_in_file_debug("groupes-non-sorted", groupes.pretty_inspect)
    end
    ExtractedFile.save_in_file_debug("groupes-non-sorted.c.", groupes_to_code(groupes))

    # 
    # Maintenant, on se retrouve avec un ensemble de groupes, 
    # +groupes+ qui contient tous les textes.
    # 

    # #@debug
    # ExtractedFile.save_in_file_debug("groupes-inserted"   , groupes.pretty_inspect)
    # ExtractedFile.save_in_file_debug("groupes-inserted.c.", groupes_to_code(groupes))

    # 
    # On récupère tous les textes
    # En en profitant pour exclure les textes à exclure
    # Si les options déterminent que les groupes (cadres) de cette
    # page doivent rester ensemble, on groupe les textes du groupe
    # 
    textes = []
    groupes.each do |groupe|
      if dont_degroup_this_page?
        text = groupe[:texts].map do |dtexte|
          next if Options.exclure?(dtexte[:text])
          dtexte[:text]
        end.compact.join("\n")
        textes << groupe[:texts][0].merge!(text: text)
      else
        groupe[:texts].each do |dtexte|
          next if Options.exclure?(dtexte[:text])
          textes << dtexte
        end
      end
    end

    # 
    # Sort all paragraphs (aka textes)
    # 
    textes = textes.sort do |atexte, btexte|
      is_first_before?(atexte, btexte)
    end

    #@debug
    if is_page_to_debug?
      ExtractedFile.save_in_file_debug("textes-sorted", textes.pretty_inspect)
    end
    ExtractedFile.save_in_file_debug("textes-sorted.c.", textes_to_code(textes))

    # 
    # Si le premier ou le dernier paragraphe sont une marque de
    # page et qu'il faut les supprimer, on les supprime
    # 
    # Note : mais le numéro de page peut se trouver ailleurs aussi.
    # 
    if config[:remove_page_number]
      text_index = nil
      textes.each_with_index do |dtexte, idx|
        if dtexte[:text].match(/^[0-9]+$/.freeze) && dtexte[:text].to_i == page_number
          text_index = idx.freeze
          break
        end
      end
      unless text_index.nil?
        supp = textes.delete_at(text_index)
      end
    end

    #@debug
    if is_page_to_debug?
      ExtractedFile.save_in_file_debug("textes-finaux", textes.pretty_inspect)
    end
    ExtractedFile.save_in_file_debug("textes-finaux.c.", textes_to_code(textes))

    # 
    # On peut maintenant faire un texte de tous ces groupes
    # et le retourner
    # Mais avant, on va ajouter une ligne vide lorsqu'il y a un
    # écart net entre deux lignes et, dans TextAffinator, d'interdire
    # la glue lorsque deux paragraphes sont séparés par une ligne
    # vide.
    # 
    texte_entier = []
    lastx = nil
    lasty = nil
    title_min_distance = config[:title_min_distance]
    y_tolerance = config[:y_tolerance]
    if is_page_to_debug?
      puts "\n\nPositionnement des textes".bleu
      puts "-------------------------".bleu
      puts "(de la page #{page_number})".bleu
      puts "x = position depuis la gauche, y = position depuis le haut".bleu
      puts "dx = différence horizontale avec le texte précédent".bleu
      puts "dy = différence verticale avec le texte précédent".bleu
      puts "\n\n"
    end
    textes.each do |dtext|
      unless lasty.nil?
        dx = dtext[:x] - lastx
        dy = dtext[:y] - lasty
        if is_page_to_debug?
          puts "x: #{jst(dtext[:x])} y: #{jst(dtext[:y])} dx: #{jst(dx)} dy: #{jst(dy)} text: #{dtext[:text]}".bleu
        end
        if dy.abs < y_tolerance 
          if dtext[:x] > lastx
            if is_page_to_debug?
              puts "  => Collé au précédent"
            end
            txt = dtext[:text]
            txt = " #{txt}" unless Options.no_space_before?(txt)
            texte_entier[-1] << txt
            next # pour ne pas ajouter ce texte après
          end
        elsif dy > title_min_distance
          texte_entier << ""
        end
      end
      texte_entier << dtext[:text]
      lastx, lasty = [dtext[:x], dtext[:y]]
    end

    texte_entier = texte_entier.join("\n")

    if is_page_to_debug?
      puts "\n\nTEXTE ENTIER DE LA PAGE #{page_number} :\n#{texte_entier}\n".jaune
    end

    return texte_entier
  end

  def jst(nombre, width = 6)
    nombre.to_s.ljust(width)
  end


  def is_page_to_debug?
    :TRUE == @ispagetodebug ||= true_or_false(CLI.options[:debug_page] && CLI.options[:debug_page].to_i == page_number)
  end

  def is_first_before?(atext, btext)
    @milieu     ||= config[:column_width]
    @ytolerance ||= config[:y_demi_tolerance]
    # 
    # Le classement des groupes passe par plusieurs strates :
    # 1. Si le groupe est dans la colonne gauche et que l'autre est
    #    dans la colonne droite, celui à gauche est forcément avant
    # 2. Si le groupe est nettement (± 14) plus bas, il est après
    # 3. Sinon, s'il est plus à droite, il est aussi après
    # 
    if page_with_only_one_colonne?
      acolumn = bcolumn = 1
    else
      acolumn = atext[:x] < @milieu ? 1 : 2
      bcolumn = btext[:x] < @milieu ? 1 : 2
    end
    if bcolumn == acolumn
      # 
      # On classe les groupes par les y (hauteur) d'abord, puis
      # par leur x s'ils sont à la même hauteur pour avoir vraiment
      # les textes dans le bon ordre.
      # 
      if atext[:y].between?(btext[:y] - @ytolerance, btext[:y] + @ytolerance)
        atext[:x] < btext[:x] ? -1 : 1
      else
        atext[:y] < btext[:y] ? -1 : 1
      end
    else
      acolumn < bcolumn ? -1 : 1
    end    
  end

  ##
  # Transforme l'attribut 'transform=matrix(...)' d'une balise <g>
  # en les valeurs :y, :x correspondantes.
  # 
  # @param  {String} Quelque chose comme "matrix(1,0,0,1,183.194,244.864)"
  # @output {:x, y:}
  # 
  def get_matrix_in(transform)
    mtx = transform.match(/matrix\((.+)\)/)
    return nil unless mtx
    mtx.to_a[1].split(',').map do |n|
      n.strip.to_f.round
    end
  end

  ##
  # @recoit les coordonnées x et y et retourne les valeurs
  # transformées par la matrice +matrix+ (cf. ci-dessus)
  # 
  def transforme_by_matrix(x, y, matrix)
    a, b, c, d, e, f = matrix
    oldx = x.freeze
    oldy = y.freeze
    newx = a * oldx + c * oldy + e  
    newy = b * oldx + d * oldy + f
    return [newx, newy]
  end

  # @return TRUE si le fichier courant est une page avec une seule
  # colonne
  def page_with_only_one_colonne?
    config[:column_width] == 0 || config[:pages_with_one_column].include?(page_number)
  end

  # @return TRUE s'il ne faut pas dégrouper cette page
  # En règle générale, les textes récupérés dans les SVG sont classés
  # par hauteur (et par colonne s'il y a deux colonnes) mais dès 
  # qu'une page présente plus de 2 colonnes, il faut mettre son 
  # numéro dans l'option :pages_not_ungrouped pour que les groupes 
  # <g> gardent leur texte ensemble.
  def dont_degroup_this_page?
    config[:pages_not_ungrouped].include?(page_number)
  end

  # Raccourci
  def config
    Options.config
  end

  def sanpxl(px)
    sanpx(px).to_s.ljust(6)
  end
  def sanpx(px)
    px[0..-3].to_i
  end


  #@debuggae
  # 
  # Pour le débuggage, on va faire un fichier avec les données
  # "alignées" qui sera plus lisible. Il sera fait pour les groupes
  # non classés ainsi que pour les groupes classés.
  # 
  def groupes_to_code(groupes)
    groupes.map do |groupe|
      "GR xr:#{groupe[:xm].to_s.ljust(6)} yr:#{groupe[:ym].to_s.ljust(6)} x:#{groupe[:x].to_s.ljust(6)} y:#{groupe[:y].to_s.ljust(6)} \n" + 
      groupe[:texts].map do |dtexte|
        "TX x :#{dtexte[:x].to_s.ljust(6)} y :#{dtexte[:y].to_s.ljust(6)} #{dtexte[:text]}" 
      end.join("\n")
    end.join("\n") + "\n(xr = x relatif, non matricé, yr = y relatif, non matricé)"
  end

  def textes_to_code(textes)
    textes.map do |dtexte|
      "TX x :#{dtexte[:x].to_s.ljust(6)} y :#{dtexte[:y].to_s.ljust(6)} #{dtexte[:text]}" 
    end.join("\n")
  end

  def page_number
    @page_number ||= filename.match(/_([0-9]+)\.svg$/).to_a[1].to_i
  end

  ##
  # Used when one text file per svg file
  # 
  def text_path
    @text_path ||= File.join(text_folder, "#{affixe}.txt")
  end
  def folder
    @folder ||= File.dirname(path)
  end
  def text_folder
    @text_folder ||= mkdir(File.join(folder,'_txt_'))
  end
  def self.remove_texts_folder
    remove_if_exist?(File.join(ExtractedFile.current.folder,'_txt_'))
  end
  def filename
    @filename ||= File.basename(path)
  end
  def affixe
    @affixe = File.basename(path, File.extname(filename))
  end
end #/SVGFile
end #/module AfPub
