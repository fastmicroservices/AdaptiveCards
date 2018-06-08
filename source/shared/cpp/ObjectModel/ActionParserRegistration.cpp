#include "pch.h"
#include "ActionParserRegistration.h"
#include "OpenUrlAction.h"
#include "ShowCardAction.h"
#include "SubmitAction.h"

namespace AdaptiveSharedNamespace {
    ActionParserRegistration::ActionParserRegistration()
    {
        m_knownElements.insert({
            ActionTypeToString(ActionType::OpenUrl),
            ActionTypeToString(ActionType::ShowCard),
            ActionTypeToString(ActionType::Submit),
        });

        m_cardElementParsers.insert({
            { ActionTypeToString(ActionType::OpenUrl), std::make_shared<OpenUrlActionParser>() },
            { ActionTypeToString(ActionType::ShowCard), std::make_shared<ShowCardActionParser>() },
            { ActionTypeToString(ActionType::Submit), std::make_shared<SubmitActionParser>() }
        });
    }

    void ActionParserRegistration::AddParser(std::string const &elementType, std::shared_ptr<ActionElementParser> parser)
    {
        if (m_knownElements.find(elementType) == m_knownElements.end())
        {
            ActionParserRegistration::m_cardElementParsers[elementType] = parser;
        }
        else
        {
            throw AdaptiveCardParseException(ErrorStatusCode::UnsupportedParserOverride, "Overriding known action parsers is unsupported");
        }
    }

    void ActionParserRegistration::RemoveParser(std::string const &elementType)
    {
        if (m_knownElements.find(elementType) != m_knownElements.end())
        {
            ActionParserRegistration::m_cardElementParsers.erase(elementType);
        }
    }

    std::shared_ptr<ActionElementParser> ActionParserRegistration::GetParser(std::string const &elementType)
    {
        auto parser = m_cardElementParsers.find(elementType);
        if (parser != ActionParserRegistration::m_cardElementParsers.end())
        {
            return parser->second;
        }
        else
        {
            return std::shared_ptr<ActionElementParser>(nullptr);
        }
    }
}
