use std::collections::{BTreeMap, BTreeSet};

use quick_xml::events::{BytesStart, Event};
use quick_xml::{Reader, XmlVersion};
use serde::{Deserialize, Serialize};
use serde_json::{Map, Value};
use tidas_assets::{AssetKind, bundled_assets};

use crate::ConversionError;

const EILCD_SCHEMA_PREFIX: &str = "assets/eilcd/schemas/";
const COMMON_NS: &str = "http://lca.jrc.it/ILCD/Common";
pub const MAX_REPORTED_UNSUPPORTED_ELEMENTS: usize = 200;

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(deny_unknown_fields)]
pub struct UnsupportedElementV1 {
    pub path: String,
    pub element: String,
}

#[derive(Clone, Debug, Default, Eq, PartialEq)]
pub struct OrderingDiagnostics {
    pub unsupported_elements: Vec<UnsupportedElementV1>,
    pub unsupported_element_count: u64,
}

impl OrderingDiagnostics {
    fn record(&mut self, path: &str, element: &str) {
        self.unsupported_element_count += 1;
        if self.unsupported_elements.len() < MAX_REPORTED_UNSUPPORTED_ELEMENTS {
            self.unsupported_elements.push(UnsupportedElementV1 {
                path: path.to_owned(),
                element: element.to_owned(),
            });
        }
    }

    #[must_use]
    pub fn is_empty(&self) -> bool {
        self.unsupported_element_count == 0
    }

    #[must_use]
    pub fn truncated(&self) -> bool {
        self.unsupported_element_count
            > u64::try_from(self.unsupported_elements.len()).unwrap_or(u64::MAX)
    }
}

#[derive(Clone, Debug, Eq, Ord, PartialEq, PartialOrd)]
struct QName {
    namespace: String,
    local: String,
}

#[derive(Clone, Debug)]
struct XsdNode {
    name: String,
    attributes: BTreeMap<String, String>,
    children: Vec<XsdNode>,
}

struct SchemaDocument {
    target_namespace: String,
    namespaces: BTreeMap<String, String>,
    root: XsdNode,
}

type ChildSpec = (String, QName, XsdNode, BTreeMap<String, String>);

/// Orders TIDAS JSON members according to the target eILCD XSD content model.
/// JSON object order is not semantic, while XML children must obey `xs:sequence`.
pub struct IlcdSchemaOrderer {
    elements: BTreeMap<QName, (XsdNode, BTreeMap<String, String>)>,
    complex_types: BTreeMap<QName, (XsdNode, BTreeMap<String, String>)>,
    groups: BTreeMap<QName, (XsdNode, BTreeMap<String, String>)>,
}

/// Compatibility alias for the original public API name.
pub type TidasSchemaOrderer = IlcdSchemaOrderer;

impl IlcdSchemaOrderer {
    pub fn from_bundled_assets() -> Result<Self, ConversionError> {
        let documents = bundled_assets()
            .into_iter()
            .filter(|asset| {
                asset.kind == AssetKind::Xsd && asset.path.starts_with(EILCD_SCHEMA_PREFIX)
            })
            .map(|asset| parse_schema(&asset.path, asset.bytes))
            .collect::<Result<Vec<_>, _>>()?;
        let mut catalog = Self {
            elements: BTreeMap::new(),
            complex_types: BTreeMap::new(),
            groups: BTreeMap::new(),
        };
        for document in documents {
            for node in &document.root.children {
                let Some(name) = node.attributes.get("name") else {
                    continue;
                };
                let key = QName {
                    namespace: document.target_namespace.clone(),
                    local: name.clone(),
                };
                let entry = (node.clone(), document.namespaces.clone());
                match node.name.as_str() {
                    "element" => {
                        catalog.elements.insert(key, entry);
                    }
                    "complexType" => {
                        catalog.complex_types.insert(key, entry);
                    }
                    "group" => {
                        catalog.groups.insert(key, entry);
                    }
                    _ => {}
                }
            }
        }
        Ok(catalog)
    }

    pub fn order_document(
        &self,
        document: &Value,
        category: &str,
    ) -> Result<Value, ConversionError> {
        self.order_document_reporting(document, category)
            .map(|(ordered, _)| ordered)
    }

    pub fn order_document_reporting(
        &self,
        document: &Value,
        _category: &str,
    ) -> Result<(Value, OrderingDiagnostics), ConversionError> {
        let object = document
            .as_object()
            .ok_or_else(|| ConversionError::OrderingSchemaMissing("JSON root object".to_owned()))?;
        if object.len() != 1 {
            return Err(ConversionError::OrderingSchemaMissing(format!(
                "single dataset root, found {}",
                object.len()
            )));
        }
        let (root_name, value) = object.iter().next().expect("one root member");
        let candidates = self
            .elements
            .iter()
            .filter(|(name, _)| name.local == *root_name)
            .collect::<Vec<_>>();
        if candidates.len() != 1 {
            return Err(ConversionError::OrderingSchemaMissing(root_name.clone()));
        }
        let (qname, (schema, namespaces)) = candidates[0];
        let mut diagnostics = OrderingDiagnostics::default();
        let mut ordered = Map::new();
        ordered.insert(
            root_name.clone(),
            self.order_element(
                value,
                qname,
                schema,
                namespaces,
                &mut BTreeSet::new(),
                root_name,
                &mut diagnostics,
            )?,
        );
        Ok((Value::Object(ordered), diagnostics))
    }

    #[allow(clippy::too_many_arguments)]
    fn order_element(
        &self,
        value: &Value,
        element_name: &QName,
        element: &XsdNode,
        namespaces: &BTreeMap<String, String>,
        resolving: &mut BTreeSet<QName>,
        path: &str,
        diagnostics: &mut OrderingDiagnostics,
    ) -> Result<Value, ConversionError> {
        if let Value::Array(items) = value {
            return items
                .iter()
                .map(|item| {
                    self.order_element(
                        item,
                        element_name,
                        element,
                        namespaces,
                        resolving,
                        path,
                        diagnostics,
                    )
                })
                .collect::<Result<Vec<_>, _>>()
                .map(Value::Array);
        }
        let Value::Object(object) = value else {
            return Ok(value.clone());
        };
        let children = self.element_children(element_name, element, namespaces, resolving)?;
        let mut ordered = Map::new();
        for (key, child_name, child_schema, child_namespaces) in children {
            if let Some(child_value) = object.get(&key) {
                ordered.insert(
                    key.clone(),
                    self.order_element(
                        child_value,
                        &child_name,
                        &child_schema,
                        &child_namespaces,
                        resolving,
                        &format!("{path}/{key}"),
                        diagnostics,
                    )?,
                );
            }
        }
        let allows_any =
            self.content_allows_any(element_name, element, namespaces, &mut BTreeSet::new())?;
        let mut remaining = Vec::new();
        for name in object.keys() {
            if ordered.contains_key(name) || name.starts_with('@') || name.starts_with('#') {
                continue;
            }
            remaining.push(name.clone());
            if !allows_any {
                diagnostics.record(path, name);
            }
        }
        remaining.sort();
        for name in remaining {
            ordered.insert(name.clone(), object[&name].clone());
        }
        for name in object.keys() {
            if name.starts_with('@') || name.starts_with('#') {
                ordered.insert(name.clone(), object[name].clone());
            }
        }
        Ok(Value::Object(ordered))
    }

    fn element_children(
        &self,
        element_name: &QName,
        element: &XsdNode,
        namespaces: &BTreeMap<String, String>,
        resolving: &mut BTreeSet<QName>,
    ) -> Result<Vec<ChildSpec>, ConversionError> {
        if !resolving.insert(element_name.clone()) {
            return Err(ConversionError::OrderingSchemaCycle(format!(
                "{}:{}",
                element_name.namespace, element_name.local
            )));
        }
        let result = if let Some(complex) = child(element, "complexType") {
            self.complex_children(complex, namespaces)
        } else if let Some(type_name) = element.attributes.get("type") {
            let qname = resolve_qname(type_name, namespaces, &element_name.namespace)?;
            match self.complex_types.get(&qname) {
                Some((complex, type_namespaces)) => self.complex_children(complex, type_namespaces),
                None => Ok(Vec::new()),
            }
        } else if let Some(reference) = element.attributes.get("ref") {
            let qname = resolve_qname(reference, namespaces, &element_name.namespace)?;
            let (target, target_namespaces) = self
                .elements
                .get(&qname)
                .ok_or_else(|| ConversionError::OrderingSchemaReference(reference.clone()))?;
            self.element_children(&qname, target, target_namespaces, resolving)
        } else {
            Ok(Vec::new())
        };
        resolving.remove(element_name);
        result
    }

    fn complex_children(
        &self,
        complex: &XsdNode,
        namespaces: &BTreeMap<String, String>,
    ) -> Result<Vec<ChildSpec>, ConversionError> {
        if let Some(content) = child(complex, "complexContent")
            && let Some(extension) = child(content, "extension")
        {
            let mut result = Vec::new();
            if let Some(base) = extension.attributes.get("base") {
                let qname = resolve_qname(base, namespaces, "")?;
                if let Some((base_type, base_namespaces)) = self.complex_types.get(&qname) {
                    result.extend(self.complex_children(base_type, base_namespaces)?);
                }
            }
            result.extend(self.particle_children(extension, namespaces)?);
            return Ok(result);
        }
        self.particle_children(complex, namespaces)
    }

    fn particle_children(
        &self,
        node: &XsdNode,
        namespaces: &BTreeMap<String, String>,
    ) -> Result<Vec<ChildSpec>, ConversionError> {
        let mut result = Vec::new();
        for particle in &node.children {
            match particle.name.as_str() {
                "sequence" | "choice" | "all" => {
                    result.extend(self.particle_children(particle, namespaces)?);
                }
                "group" => {
                    if let Some(reference) = particle.attributes.get("ref") {
                        let qname = resolve_qname(reference, namespaces, "")?;
                        let (group, group_namespaces) =
                            self.groups.get(&qname).ok_or_else(|| {
                                ConversionError::OrderingSchemaReference(reference.clone())
                            })?;
                        result.extend(self.particle_children(group, group_namespaces)?);
                    }
                }
                "element" => result.push(self.resolve_element(particle, namespaces)?),
                _ => {}
            }
        }
        Ok(result)
    }

    fn content_allows_any(
        &self,
        element_name: &QName,
        element: &XsdNode,
        namespaces: &BTreeMap<String, String>,
        resolving: &mut BTreeSet<QName>,
    ) -> Result<bool, ConversionError> {
        if !resolving.insert(element_name.clone()) {
            return Ok(false);
        }
        let result = if let Some(complex) = child(element, "complexType") {
            self.complex_allows_any(complex, namespaces)
        } else if let Some(type_name) = element.attributes.get("type") {
            let qname = resolve_qname(type_name, namespaces, &element_name.namespace)?;
            match self.complex_types.get(&qname) {
                Some((complex, type_namespaces)) => {
                    self.complex_allows_any(complex, type_namespaces)
                }
                None => Ok(false),
            }
        } else if let Some(reference) = element.attributes.get("ref") {
            let qname = resolve_qname(reference, namespaces, &element_name.namespace)?;
            let (target, target_namespaces) = self
                .elements
                .get(&qname)
                .ok_or_else(|| ConversionError::OrderingSchemaReference(reference.clone()))?;
            self.content_allows_any(&qname, target, target_namespaces, resolving)
        } else {
            Ok(false)
        };
        resolving.remove(element_name);
        result
    }

    fn complex_allows_any(
        &self,
        complex: &XsdNode,
        namespaces: &BTreeMap<String, String>,
    ) -> Result<bool, ConversionError> {
        if let Some(content) = child(complex, "complexContent")
            && let Some(extension) = child(content, "extension")
        {
            let mut allowed = false;
            if let Some(base) = extension.attributes.get("base") {
                let qname = resolve_qname(base, namespaces, "")?;
                if let Some((base_type, base_namespaces)) = self.complex_types.get(&qname) {
                    allowed = self.complex_allows_any(base_type, base_namespaces)?;
                }
            }
            allowed |= self.particle_allows_any(extension, namespaces)?;
            return Ok(allowed);
        }
        self.particle_allows_any(complex, namespaces)
    }

    fn particle_allows_any(
        &self,
        node: &XsdNode,
        namespaces: &BTreeMap<String, String>,
    ) -> Result<bool, ConversionError> {
        let mut allowed = false;
        for particle in &node.children {
            match particle.name.as_str() {
                "sequence" | "choice" | "all" => {
                    allowed |= self.particle_allows_any(particle, namespaces)?;
                }
                "group" => {
                    if let Some(reference) = particle.attributes.get("ref") {
                        let qname = resolve_qname(reference, namespaces, "")?;
                        let (group, group_namespaces) =
                            self.groups.get(&qname).ok_or_else(|| {
                                ConversionError::OrderingSchemaReference(reference.clone())
                            })?;
                        allowed |= self.particle_allows_any(group, group_namespaces)?;
                    }
                }
                "any" => allowed = true,
                _ => {}
            }
        }
        Ok(allowed)
    }

    fn resolve_element(
        &self,
        element: &XsdNode,
        namespaces: &BTreeMap<String, String>,
    ) -> Result<ChildSpec, ConversionError> {
        if let Some(reference) = element.attributes.get("ref") {
            let qname = resolve_qname(reference, namespaces, "")?;
            let (target, target_namespaces) = self
                .elements
                .get(&qname)
                .ok_or_else(|| ConversionError::OrderingSchemaReference(reference.clone()))?;
            return Ok((
                json_key(&qname),
                qname,
                target.clone(),
                target_namespaces.clone(),
            ));
        }
        let local = element
            .attributes
            .get("name")
            .ok_or_else(|| ConversionError::OrderingSchemaReference("local element".to_owned()))?;
        let qname = QName {
            namespace: namespaces.get("").cloned().unwrap_or_default(),
            local: local.clone(),
        };
        Ok((json_key(&qname), qname, element.clone(), namespaces.clone()))
    }
}

fn parse_schema(path: &str, bytes: &[u8]) -> Result<SchemaDocument, ConversionError> {
    let mut reader = Reader::from_reader(bytes);
    reader.config_mut().trim_text(true);
    let mut buffer = Vec::new();
    let mut stack: Vec<XsdNode> = Vec::new();
    let mut root = None;
    loop {
        match reader.read_event_into(&mut buffer)? {
            Event::Start(start) => stack.push(parse_node(&reader, &start)?),
            Event::Empty(start) => {
                let node = parse_node(&reader, &start)?;
                if let Some(parent) = stack.last_mut() {
                    parent.children.push(node);
                }
            }
            Event::End(_) => {
                let node = stack.pop().ok_or(ConversionError::UnmatchedEnd)?;
                if let Some(parent) = stack.last_mut() {
                    parent.children.push(node);
                } else {
                    root = Some(node);
                }
            }
            Event::Eof => break,
            _ => {}
        }
        buffer.clear();
    }
    let root = root.ok_or(ConversionError::MissingRoot)?;
    let target_namespace = root
        .attributes
        .get("targetNamespace")
        .cloned()
        .or_else(|| (path.ends_with("ILCD_Common_Validation.xsd")).then(|| COMMON_NS.to_owned()))
        .ok_or_else(|| ConversionError::OrderingSchemaMissing(path.to_owned()))?;
    let mut namespaces = root
        .attributes
        .iter()
        .filter_map(|(key, value)| {
            key.strip_prefix("xmlns:")
                .map(|prefix| (prefix.to_owned(), value.clone()))
        })
        .collect::<BTreeMap<_, _>>();
    namespaces.insert(String::new(), target_namespace.clone());
    Ok(SchemaDocument {
        target_namespace,
        namespaces,
        root,
    })
}

fn parse_node(reader: &Reader<&[u8]>, start: &BytesStart<'_>) -> Result<XsdNode, ConversionError> {
    let qualified = reader.decoder().decode(start.name().as_ref())?.into_owned();
    let name = qualified
        .rsplit(':')
        .next()
        .unwrap_or(&qualified)
        .to_owned();
    let mut attributes = BTreeMap::new();
    for attribute in start.attributes() {
        let attribute = attribute?;
        let key = reader
            .decoder()
            .decode(attribute.key.as_ref())?
            .into_owned();
        let value = attribute
            .decoded_and_normalized_value(XmlVersion::Implicit1_0, reader.decoder())?
            .into_owned();
        attributes.insert(key, value);
    }
    Ok(XsdNode {
        name,
        attributes,
        children: Vec::new(),
    })
}

fn child<'a>(node: &'a XsdNode, name: &str) -> Option<&'a XsdNode> {
    node.children.iter().find(|child| child.name == name)
}

fn resolve_qname(
    value: &str,
    namespaces: &BTreeMap<String, String>,
    fallback_namespace: &str,
) -> Result<QName, ConversionError> {
    let (prefix, local) = value.split_once(':').unwrap_or(("", value));
    let namespace = namespaces
        .get(prefix)
        .cloned()
        .or_else(|| (!fallback_namespace.is_empty()).then(|| fallback_namespace.to_owned()))
        .ok_or_else(|| ConversionError::OrderingSchemaReference(value.to_owned()))?;
    Ok(QName {
        namespace,
        local: local.to_owned(),
    })
}

fn json_key(name: &QName) -> String {
    if name.namespace == COMMON_NS {
        format!("common:{}", name.local)
    } else {
        name.local.clone()
    }
}

#[cfg(test)]
mod tests {
    use serde_json::json;

    use super::*;

    #[test]
    fn target_elements_missing_from_the_content_model_are_reported() {
        let orderer = IlcdSchemaOrderer::from_bundled_assets().unwrap();
        let document = json!({
            "processDataSet": {
                "exchanges": {
                    "exchange": {
                        "generalComment": {"@xml:lang": "en", "#text": "comment"},
                        "referenceToDataSource": {"@refObjectId": "source"}
                    }
                }
            }
        });
        let (_, diagnostics) = orderer
            .order_document_reporting(&document, "processes")
            .unwrap();
        assert_eq!(diagnostics.unsupported_element_count, 1);
        assert_eq!(
            diagnostics.unsupported_elements[0].element,
            "referenceToDataSource"
        );
        assert!(
            diagnostics.unsupported_elements[0]
                .path
                .ends_with("/exchange")
        );
    }

    #[test]
    fn eilcd_data_source_collection_is_not_reported() {
        let orderer = IlcdSchemaOrderer::from_bundled_assets().unwrap();
        let document = json!({
            "processDataSet": {
                "exchanges": {
                    "exchange": {
                        "referencesToDataSource": {
                            "referenceToDataSource": {"@refObjectId": "source"}
                        }
                    }
                }
            }
        });
        let (sorted_document, diagnostics) = orderer
            .order_document_reporting(&document, "processes")
            .unwrap();
        assert!(diagnostics.is_empty());
        assert!(
            sorted_document
                .pointer("/processDataSet/exchanges/exchange/referencesToDataSource")
                .is_some()
        );
    }
}
